Schema and views frozen byte-for-byte from the public `mimir` revision
`fde18300fe9c78dd669650a1b7b36c195db77804`, before accounting tables were added.
The upgrade test creates and closes a retained file from these statements
before opening it with the current reader.
