The JSON of the copy commands of paddock 0.2.4, written by hand from the
shapes in core src/copy/json.rs (see FilesContractTests). No file here is the
output of a real paddock yet.

In the contract: every key of copies, changes*, backups*, pointer*, and the
keys api_version, run, project and paths of the action results.
Not in the contract (guesses): the values of method, git, base, carried,
conflict, encryption, size.kind, backup kind and words, pointer state and
action, and the other keys of apply.json, restore.json and undo.json.
