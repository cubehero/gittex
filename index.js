(function() {
  var async, child, gitteh, path;

  child = require('child_process');

  path = require('path');

  async = require('async');

  gitteh = require('gitteh');

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

  exports.isFile = function(entry) {
    return entry.attributes === 33188;
  };

  exports.isDirectory = function(entry) {
    return entry.attributes === 16384;
  };

  exports.walkTree = function(repo, commit, callback, doneCallback) {
    var walkTreeHelper;
    walkTreeHelper = function(treeSha, currPath, iteratorCallback, doneCallback) {
      return repo.getTree(treeSha, function(err, tree) {
        if (err != null) doneCallback(err);
        return async.waterfall([
          function(seriesNext) {
            return async.forEach(tree.entries.filter(this.isFile), function(entry, forEachFileNext) {
              entry.path = currPath;
              return iteratorCallback(entry, forEachFileNext);
            }, seriesNext);
          }, function(seriesNext) {
            return async.forEach(tree.entries.filter(this.isDirectory), function(entry, forEachDirNext) {
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

}).call(this);
