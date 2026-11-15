#!/usr/bin/env node
import { main } from "./cli.js";

main().then((code) => {
  if (code !== 0) process.exitCode = code;
});
