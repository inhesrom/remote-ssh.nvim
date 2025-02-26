# remote-ssh-nvim

## Remote Development, Local Feel
This plugin is intended to recreate similar behavior to VS Code's Remote SSH plugin by enabling the feel of a local editor while keeping the project on the remote machine for compilation, execution, etc

netrw already allows for editing remote files locally by scp'ing them to and from a remote machine, allowing for local editing but remote saving

This plugin extends that functionality by automatically starting the appropriate language server on the remote server where the buffer was opened from, allowing all the magic of LSP, but with your project and LSP running on another server, like VS Code

## How to Use
Open a netrw buffer from neovim
```
:e scp://user@host//<full_file_path_here>
```
Plugin will automatically start the supported LSP server on the remote machine defined by user@host in the parent directory of the file, but the project root directory can be manually changed using a user command

## Configuration



## User Commands

```
:RemoteLspStart
```

```
:RemoteLspStop
```


