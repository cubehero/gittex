# These are gitteh extensions. Not fully tested because the fast_forward
# sha hashes are for coffeecup, and not robokitty

child = require('child_process')
path = require('path')

# FIXME how to include async and gitteh in post commit hooks?
async = require('async')
gitteh = require('gitteh')

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

  # should start with walkTreeHelper(commit.tree, '/', [], (err) -> )
  walkTreeHelper = (treeSha, currPath, iteratorCallback, doneCallback) ->
    repo.getTree treeSha, (err, tree) ->
      doneCallback(err) if err?

      async.waterfall([
        (seriesNext) ->
          async.forEach(tree.entries.filter(@isFile),
            (entry, forEachFileNext) ->
              entry.path = currPath
              iteratorCallback(entry, forEachFileNext)
            , seriesNext
          )
        ,
        (seriesNext) ->
          async.forEach(tree.entries.filter(@isDirectory),
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

# walk the tree and return each file filtered by condition

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


