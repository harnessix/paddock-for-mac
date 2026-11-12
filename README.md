# paddock for Mac

paddock for Mac runs Mac apps in a sandbox. Each app runs in its own macOS virtual machine, and its windows show on your desktop like any other app. You decide which servers the app can reach and which folders it can see.

Each app lives in its own small room with a keeper. While the app runs, the keeper works. When the app asks to reach a new server, the keeper raises a flag. While the app is stopped, the keeper sleeps.

## Status

paddock for Mac is in development. The first release needs [paddock](https://github.com/harnessix/paddock) 0.2.3 or newer, which is not out yet. Watch this repository for the first release.

## What you need

- A Mac with Apple silicon (M1 or newer)
- macOS 14 or newer
- About 40 GB of free space for the base image
- The paddock command:

  ```sh
  brew tap harnessix/paddock
  brew install paddock
  ```

## Related

- [paddock](https://github.com/harnessix/paddock): the command-line tool. It runs coding agents and desktop apps in sandboxes on Linux and macOS.

## License

MIT. See [LICENSE](LICENSE).
