(function() {
  var async, child, fs, gitteh, path;

  child = require('child_process');

  path = require('path');

  async = require('async');

  gitteh = require('gitteh');

  fs = require('fs');

  exports.isFile = function(entry) {
    return entry.attributes === 33188;
  };

  exports.isDirectory = function(entry) {
    return entry.attributes === 16384;
  };

  exports.walkTree = function(repo, commit, callback, doneCallback) {
    var that, walkTreeHelper;
    that = this;
    walkTreeHelper = function(treeSha, currPath, iteratorCallback, doneCallback) {
      return repo.getTree(treeSha, function(err, tree) {
        var _this = this;
        if (err != null) doneCallback(err);
        return async.waterfall([
          function(seriesNext) {
            return async.forEach(tree.entries.filter(that.isFile), function(entry, forEachFileNext) {
              entry.path = currPath;
              return iteratorCallback(entry, forEachFileNext);
            }, seriesNext);
          }, function(seriesNext) {
            return async.forEach(tree.entries.filter(that.isDirectory), function(entry, forEachDirNext) {
              var newCurrPath;
              newCurrPath = path.join(currPath, entry.name);
              return walkTreeHelper(entry.id, newCurrPath, iteratorCallback, function(err, currPath) {
                return forEachDirNext(err, currPath);
              });
            }, function(err) {
              return seriesNext(null, currPath);
            });
          }
        ], function(err, results) {
          return doneCallback(null, results);
        });
      });
    };
    return walkTreeHelper(commit.tree, '/', function(entry, next) {
      return callback(entry, next);
    }, function(err, currPath) {
      return doneCallback(err);
    });
  };

  exports.findInTree = function(repo, commit, comparison, callback) {
    var comp, files;
    files = [];
    if (typeof comparison === "string") {
      comp = function(entry) {
        return entry.name.match(comparison) !== null;
      };
    } else if (typeof comparison === "function") {
      comp = comparison;
    } else {
      throw new Error("Comparison is not a string or function");
    }
    return this.walkTree(repo, commit, function(entry, walkTreeNext) {
      if (comp(entry) === true) files.push(entry);
      return walkTreeNext();
    }, function(err) {
      return callback(err, files);
    });
  };

  exports.isExistInTree = function(fileName, treeSha, repo) {
    var entry, sha, tree, _i, _len, _ref;
    tree = repo.getTree(treeSha);
    _ref = tree.entries;
    for (_i = 0, _len = _ref.length; _i < _len; _i++) {
      entry = _ref[_i];
      if (entry.attributes === 33188) {
        if (entry.name === fileName) return entry.id;
      } else {
        sha = this.isExistInTree(fileName, entry.id, repo);
        if (sha) return sha;
      }
    }
    return null;
  };

  exports.find_common_ancestor = function(oldrev, newrev, callback) {
    return child.exec("git merge-base " + oldrev + " " + newrev, {
      cwd: path.join(__dirname, '..')
    }, function(err, stdout, stdin) {
      var common_sha;
      if (err != null) {
        callback(err);
        return;
      }
      common_sha = stdout.replace(/\s+/, '');
      return callback(null, common_sha);
    });
  };

  exports.eachNewCommit = function(repo, oldrev, newrev, callback, doneCallback) {
    return this.find_common_ancestor(oldrev, newrev, function(err, common_sha) {
      var commit, commits, walker;
      walker = repo.createWalker();
      walker.sort(gitteh.GIT_SORT_TOPOLOGICAL);
      walker.push(newrev);
      commits = [];
      while ((commit = walker.next())) {
        if (commit.id === common_sha) break;
        commits.push(commit);
      }
      return async.forEachSeries(commits, callback, function(err) {
        return doneCallback(err, commits.length);
      });
    });
  };

  exports.fileHistory = function(repo, commitSha, fileName) {
    var blobSha, commit, commits, headRef, lastBlobSha, walker;
    lastBlobSha = null;
    commits = [];
    headRef = repo.getReference('HEAD');
    headRef = headRef.resolve();
    walker = repo.createWalker();
    walker.sort(gitteh.GIT_SORT_TOPOLOGICAL);
    walker.push(headRef.target);
    while ((commit = walker.next())) {
      blobSha = this.isExistInTree(fileName, commit.tree, repo);
      console.log("blobSha: " + blobSha);
      if ((blobSha != null) && blobSha !== lastBlobSha) {
        commits.push({
          commit: commit,
          blob: repo.getBlob(blobSha)
        });
        lastBlobSha = blobSha;
      }
    }
    return commits;
  };

  exports.findPreviousBlob = function(repo, currCommit, entryToFind, callback) {
    var prevSha;
    prevSha = currCommit.parents[0];
    console.log(prevSha);
    return repo.getCommit(prevSha, function(err, prevCommit) {
      var foundEntry;
      foundEntry = null;
      return this.walkTree(repo, prevCommit, function(entry, next) {
        if (entry.path === entryToFind.path && entry.name === entryToFind.name) {
          foundEntry = entry;
        }
        return next(null);
      }, function(err) {
        return callback(err, prevCommit, foundEntry);
      });
    });
  };

  exports.openCurrAndPrev = function(repoPath, currSha, prevSha, callback) {
    return gitteh.openRepository(repoPath, function(err, repo) {
      if (err != null) callback(err);
      return repo.getBlob(currSha, function(err, currBlob) {
        if (err != null) callback(err);
        return repo.getBlob(prevSha, function(err, prevBlob) {
          return callback(err, currBlob, prevBlob);
        });
      });
    });
  };

  exports.runPostReceiveHook = function(repoPath, oldrev, newrev, refName, callback) {
    var hookPath;
    hookPath = path.join(repoPath, 'hooks', 'post-receive');
    console.log('in gitteh');
    return fs.stat(hookPath, function(err, stat) {
      var hook;
      console.log('statted ', repoPath);
      if ((err != null) && err.errno !== 34) {
        callback(err);
        return;
      }
      console.log('if stat?');
      if (stat != null) {
        console.log('has post-receive');
        console.log('hookPath', hookPath);
        console.log('#hookPath', "" + hookPath);
        hook = child.exec("" + hookPath, callback);
        return hook.stdin.end("" + oldrev + " " + newrev + " " + refName);
      } else {
        return callback(null, "", "");
      }
    });
  };

  exports.nativeGit = function(cmd) {
    var arg, args, argv, callback, gitBinary, gitCmd, gitDir, isDebug, options, options_to_argv, stderrBufs, stdoutBufs, workTree, _i, _j, _len, _len2, _result;
    options_to_argv = function(options) {
      var argv, key, val;
      argv = [];
      for (key in options) {
        val = options[key];
        if (key.toString().length === 1) {
          if (val === true) {
            argv.push("-" + key);
          } else if (val === false) {} else {
            argv.push("-" + key);
            argv.push(val.toString());
          }
        } else {
          if (val === true) {
            argv.push("--" + (key.toString().replace('_', '-')));
          } else if (val === false) {} else {
            argv.push("--" + (key.toString().replace('_', '-')) + "=" + val);
          }
        }
      }
      return argv;
    };
    callback = arguments[arguments.length - 1];
    if (arguments.length === 4) {
      options = arguments[1];
      args = arguments[2];
    } else if (arguments.length === 3) {
      options = arguments[1];
      args = [];
    } else if (arguments.length === 2) {
      options = {};
      args = [];
    } else {
      options = {};
      args = [];
      callback = function() {};
    }
    options = options || {};
    isDebug = options.debug;
    delete options.debug;
    args = args || [];
    _result = [];
    for (_i = 0, _len = args.length; _i < _len; _i++) {
      arg = args[_i];
      _result.push(arg.toString());
    }
    args = _result;
    _result = [];
    for (_j = 0, _len2 = args.length; _j < _len2; _j++) {
      arg = args[_j];
      if (arg.length !== 0) _result.push(arg);
    }
    args = _result;
    gitBinary = 'git';
    gitDir = options.git_dir;
    delete options.git_dir;
    workTree = options.work_tree;
    delete options.work_tree;
    argv = [];
    if (gitDir != null) argv.push("--git-dir=" + gitDir);
    if (workTree != null) argv.push("--work-tree=" + workTree);
    argv.push(cmd);
    argv = argv.concat(options_to_argv(options));
    argv = argv.concat(args);
    if (isDebug === true) console.log(gitBinary, argv);
    gitCmd = child.spawn(gitBinary, argv, options);
    stdoutBufs = [];
    gitCmd.stdout.on('data', function(data) {
      if (isDebug === true) console.log(data.toString());
      return stdoutBufs.push(data);
    });
    stderrBufs = [];
    gitCmd.stderr.on('data', function(data) {
      if (isDebug === true) console.log(data.toString());
      return stderrBufs.push(data);
    });
    gitCmd.on('exit', function(exitCode, signal) {
      var buf, err, stderrBuf, stdoutBuf, _k, _l, _len3, _len4;
      if (exitCode > 1) {
        err = new Error("error on command: " + exitCode);
        callback(err, stdoutBuf, stderrBuf);
        return;
      }
      stdoutBuf = "";
      for (_k = 0, _len3 = stdoutBufs.length; _k < _len3; _k++) {
        buf = stdoutBufs[_k];
        stdoutBuf = stdoutBuf.concat(buf.toString());
      }
      stderrBuf = "";
      for (_l = 0, _len4 = stderrBufs.length; _l < _len4; _l++) {
        buf = stderrBufs[_l];
        stderrBuf = stderrBuf.concat(buf.toString());
      }
      return callback(null, stdoutBuf, stderrBuf);
    });
    return gitCmd;
  };

}).call(this);
