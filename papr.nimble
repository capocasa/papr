version       = "0.1.2"
author        = "capocasa"
description   = "Paperless-ngx CLI for listing, inspecting and downloading documents"
license       = "MIT"
srcDir        = "src"
bin           = @["papr"]

requires "nim >= 2.0.0"
requires "cligen"
requires "dotenv"
