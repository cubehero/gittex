# These are gitteh extensions. Not fully tested because the fast_forward
# sha hashes are for coffeecup, and not robokitty

child = require('child_process')
path = require('path')

# FIXME how to include async and gitteh in post commit hooks?
async = require('async')
gitteh = require('gitteh')
fs = require('fs')

####### Tree related gitteh extensions #######

# if a tree entry is a file.
exports.isFile = (entry) -> entry.attributes is 33188

# if a tree entry is a directory.
# 16384 == 40000 in octal (which is directory attribute in Git).
exports.isDirectory = (entry) -> entry.attributes is 16384

# walk the tree breadth first and return each file
#
# @param - Repository - repo
# @param - Commit - commit
# @param - Function - callback(entry, currPath, next)
#   TreeEntry - entry - the entry for the file or directory
#   Function - next - call after finished with iteration
# @param - Function - doneCallback(err)
#   Error - err
exports.walkTree = (repo, commit, callback, doneCallback) ->
  that = @

  # should start with walkTreeHelper(commit.tree, '/', [], (err) -> )
  walkTreeHelper = (treeSha, currPath, iteratorCallback, doneCallback) ->
    repo.getTree treeSha, (err, tree) ->
      doneCallback(err) if err?

      async.waterfall([
        (seriesNext) =>
          async.forEach(tree.entries.filter(that.isFile),
            (entry, forEachFileNext) ->
              entry.path = currPath
              iteratorCallback(entry, forEachFileNext)
            , seriesNext
          )
        ,
        (seriesNext) ->
          async.forEach(tree.entries.filter(that.isDirectory),
            (entry, forEachDirNext) ->
              newCurrPath = path.join(currPath, entry.name)
              # console.log(" going one level down...#{newCurrPath}")
              walkTreeHelper(entry.id, newCurrPath, iteratorCallback,
                (err, currPath) ->
                  # console.log("one directory is done at #{currPath}")
                  forEachDirNext(err, currPath)
              )
            ,
            (err) ->
              # console.log("finished all files and dirs in #{currPath}")
              seriesNext(null, currPath)
          )
      ],
        (err, results) ->
          doneCallback(null, results)
      )
   
  walkTreeHelper(commit.tree, '/', (entry, next) ->
    # console.log("fileName visited: #{path.join(currPath, entry.name)}")
    callback(entry, next)
  , (err, currPath) ->
    # finished processing entire tree
    doneCallback(err)
  )
  
# finds a file in the tree matching the comparison criteria. Comparison
# can either be a regex string or a function that takes entry as a parameter
# and returns true or false
#
# repo - the repository
# commit - the commit to look in the tree
# comparison - a regex string
#   or a function(entry), where entry is the data structure in gitteh
# callback - function(err, files)
#   returns err object, and an array of matching files
#
exports.findInTree = (repo, commit, comparison, callback) ->
  files = []

  if typeof comparison is "string"
    comp = (entry) -> entry.name.match(comparison) isnt null
  else if typeof comparison is "function"
    comp = comparison
  else
    throw new Error("Comparison is not a string or function")

  @walkTree(repo, commit, (entry, walkTreeNext) ->
    if comp(entry) is true
      files.push(entry)
    walkTreeNext()
  , (err) ->
    callback(err, files)
  )

# Does a file exist within a tree? It recursively searches, breadth first
#
# TODO rewrite using findInTree, since it's async. This is sync
exports.isExistInTree = (fileName, treeSha, repo) ->
  tree = repo.getTree treeSha
  for entry in tree.entries
    if entry.attributes is 33188
      if entry.name is fileName
        return entry.id
    else
      sha = @isExistInTree(fileName, entry.id, repo)
      return sha if sha
  return null

######### Commit traversal gitteh extensions ##########

# Find the common ancestor between old and new revs
# and then yield all commits that need to be diff'd
#
# @param - String - oldrev
# @param - String - newrev
# @param - Function - callback(err, common_sha)
#   - Error - err
#   - String - common_sha
#
exports.find_common_ancestor = (oldrev, newrev, callback) ->
  child.exec "git merge-base #{oldrev} #{newrev}", { cwd: path.join(__dirname, '..') },
    (err, stdout, stdin) ->
      (callback(err); return) if err?
      common_sha = stdout.replace(/\s+/, '')
      callback(null, common_sha)

# returns each new commit since the last commit
#
# @param - String - oldrev
# @param - String - newrev
# @param - Function - callback(err, common_sha, next)
#   - String - common_sha
#   - Function - next - called when done with the iteration
# @param - Function - doneCallback(err, number)
#   - Error - err
#   - Number - number of commits
#
exports.eachNewCommit = (repo, oldrev, newrev, callback, doneCallback) ->
  @find_common_ancestor(oldrev, newrev, (err, common_sha) ->
    walker = repo.createWalker()
    walker.sort(gitteh.GIT_SORT_TOPOLOGICAL)
    walker.push(newrev)

    commits = []
    while(commit = walker.next())
      break if commit.id == common_sha
      commits.push(commit)

    async.forEachSeries(commits, callback
      , (err) ->
        doneCallback(err, commits.length)
    )
  )


# The history for a file, whenever it changes.
# TODO only shows history from master, because by the time we browse to the file
# we don't have the commit hash, but only the blob hash of the file
#
# returns an array of hashes
# where each hash contains two key/value pairs:
#
# commit: commit where the change occured
# blob: blob in that commit for that file
exports.fileHistory = (repo, commitSha, fileName) ->
  lastBlobSha = null
  commits = []

  headRef = repo.getReference('HEAD')
  headRef = headRef.resolve()

  walker = repo.createWalker()
  walker.sort(gitteh.GIT_SORT_TOPOLOGICAL)
  walker.push(headRef.target)

  while(commit = walker.next())
    blobSha = @isExistInTree(fileName, commit.tree, repo)
    console.log "blobSha: #{blobSha}"

    if (blobSha? and blobSha != lastBlobSha)
      commits.push({ commit: commit, blob: repo.getBlob(blobSha) })
      lastBlobSha = blobSha
  return commits


exports.findPreviousBlob = (repo, currCommit, entryToFind, callback) ->
  # TODO currently don't know what to do about multiple parents
  prevSha = currCommit.parents[0]
  console.log prevSha
  repo.getCommit(prevSha, (err, prevCommit) ->
    # look for entry's blob
    # Since we can't break, we just have to flag what we found and run through the entire tree
    foundEntry = null
    @walkTree(repo, prevCommit, (entry, next) ->
      if entry.path is entryToFind.path and entry.name is entryToFind.name
        foundEntry = entry
      next(null)
    , (err) ->
      callback(err, prevCommit, foundEntry)
    )

  )

exports.openCurrAndPrev = (repoPath, currSha, prevSha, callback) ->
  gitteh.openRepository repoPath, (err, repo) ->
    callback(err) if err?
    # FIXME getBlob throws errors too apparently, if argument 0 is not an oid
    repo.getBlob currSha, (err, currBlob) ->
      callback(err) if err?
      repo.getBlob prevSha, (err, prevBlob) ->
        callback(err, currBlob, prevBlob)

exports.runPostReceiveHook = (repoPath, oldrev, newrev, refName, callback) ->
  hookPath = path.join(repoPath, 'hooks', 'post-receive')

  console.log 'in gitteh'

  fs.stat(hookPath, (err, stat) ->
    console.log 'statted ', repoPath
    (callback(err); return) if (err? and err.errno isnt 34)
    console.log 'if stat?'
    if stat?
      console.log 'has post-receive'
      console.log 'hookPath', hookPath
      console.log "#{oldrev} #{newrev} #{refName}"

      hook = child.exec(hookPath, callback)
      hook.stdin.end("#{oldrev} #{newrev} #{refName}")
    else
      callback(null, "", "")
  )

##### Committing, Adding, Pushing, and Pulling

exports.clone = (repoPath, workingPath, callback) ->
  @nativeGit('clone', { debug: true }, [repoPath, workingPath], callback)

exports.pull = (workingPath, callback) ->
  @nativeGit('pull', { debug: true, cwd: workingPath }, callback)

exports.add = (workingPath, callback) ->
  @nativeGit('add', { debug: true, cwd: workingPath }, ['.'], callback)

exports.commit = (workingPath, author, message, callback) ->
  @nativeGit('commit', { author: author, m: message, cwd: workingPath }, callback)

# defaults to pushing to origin:master
exports.push = (workingPath, callback) ->
  @nativeGit('push', { cwd: workingPath, u: 'origin' }, ['master'], callback)

# stages a file removal from the repo
exports.remove = (workingPath, filePath, callback) ->
  @nativeGit('rm', { debug: true, cwd: workingPath }, [filePath], callback)

##### Raw execution of git through a native command line call #####

# Execute a git command on the system. A port of Grit's native cmd in git.rb
#
# cmd - The name of the git command as a Symbol. Underscores are
#   converted to dashes as in :rev_parse => 'rev-parse'.
# options - Command line option arguments passed to the git command.
#   Single char keys are converted to short options (:a => -a).
#   Multi-char keys are converted to long options (:arg => '--arg').
#   Underscores in keys are converted to dashes. These special options
#   are used to control command execution and are not passed in command
#   invocation:
#     :git_dir - where the root path of the repository is
#     :work_tree - where the working tree is
#     :debug - Show debug information
#
#     # The following aren't yet implemented
#     :timeout - Maximum amount of time the command can run for before
#       being aborted. When true, use Grit::Git.git_timeout; when numeric,
#       use that number of seconds; when false or 0, disable timeout.
#     :base - Set false to avoid passing the --git-dir argument when
#       invoking the git command.
#     :env - Hash of environment variable key/values that are set on the
#       child process.
#     :raise - When set true, commands that exit with a non-zero status
#       raise a CommandFailed exception. This option is available only on
#       platforms that support fork(2).
#     :process_info - By default, a single string with output written to
#       the process's stdout is returned. Setting this option to true
#       results in a [exitstatus, out, err] tuple being returned instead.
# args - Non-option arguments passed on the command line.
#
# callback - function(err, stdout, stderr)
#
# Examples
#   git.native(:rev_list, {:max_count => 10, :header => true}, "master")
#
# Returns a String with all output written to the child process's stdout
#   when the :process_info option is not set.
# Returns a [exitstatus, out, err] tuple when the :process_info option is
#   set. The exitstatus is an small integer that was the process's exit
#   status. The out and err elements are the data written to stdout and
#   stderr as Strings.
# Raises Grit::Git::GitTimeout when the timeout is exceeded or when more
#   than Grit::Git.git_max_size bytes are output.
# Raises Grit::Git::CommandFailed when the :raise option is set true and the
#   git command exits with a non-zero exit status. The CommandFailed's #command,
#   #exitstatus, and #err attributes can be used to retrieve additional
#   detail about the error.
#
exports.nativeGit = (cmd) ->
  options_to_argv = (options) ->
    argv = []
    for key, val of options
      if key.toString().length is 1
        if val is true
          argv.push "-#{key}"
        else if val is false
          # ignore
        else
          argv.push "-#{key}"
          argv.push val.toString()
      else
        if val is true
          argv.push "--#{key.toString().replace('_', '-')}"
        else if val is false
          #ignore
        else
          argv.push "--#{key.toString().replace('_', '-')}=#{val}"
    argv

  callback = arguments[arguments.length - 1]
  if arguments.length is 4        # nativeGit(cmd, options, args, callback)
    options = arguments[1]
    args = arguments[2]
  else if arguments.length is 3   # nativeGit(cmd, options, callback)
    options = arguments[1]
    args = []
  else if arguments.length is 2   # nativeGit(cmd, callback)
    options = {}
    args = []
  else                            # nativeGit(cmd)
    options = {}
    args = []
    callback = () ->

  options = options || {}
  isDebug = options.debug; delete options.debug
  spawnOptions = {}
  if options.cwd?
    spawnOptions.cwd = options.cwd
    delete options.cwd

  args = args || []
  _result = []; for arg in args
    _result.push arg.toString()
  args = _result
  _result = []; for arg in args
    _result.push(arg) if arg.length isnt 0
  args = _result

  gitBinary = 'git'
  gitDir =  options.git_dir; delete options.git_dir
  workTree = options.work_tree; delete options.work_tree

  argv = []
  argv.push "--git-dir=#{gitDir}" if gitDir?
  argv.push "--work-tree=#{workTree}" if workTree?
  argv.push cmd
  argv = argv.concat options_to_argv(options)
  argv = argv.concat args

  console.log(gitBinary, argv, spawnOptions) if isDebug is true
  gitCmd = child.spawn(gitBinary, argv, spawnOptions)
  stdoutBufs = []
  gitCmd.stdout.on('data', (data) ->
    console.log(data.toString()) if isDebug is true
    stdoutBufs.push(data)
  )
  stderrBufs = []
  gitCmd.stderr.on('data', (data) ->
    console.log(data.toString()) if isDebug is true
    stderrBufs.push(data)
  )

  gitCmd.on 'exit', (exitCode, signal) ->
    if exitCode > 1
      gitErrMsg = "gittex error on native command: #{exitCode}"
      err = new Error(gitErrMsg)
      err.msg = gitErrMsg
      err.errno = exitCode
      callback(err, stdoutBuf, stderrBuf)
      return
    stdoutBuf = ""; for buf in stdoutBufs
      stdoutBuf = stdoutBuf.concat(buf.toString())
    stderrBuf = ""; for buf in stderrBufs
      stderrBuf = stderrBuf.concat(buf.toString())
    callback(null, stdoutBuf, stderrBuf)

  return gitCmd

