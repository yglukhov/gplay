# Package

version       = "0.1.0"
author        = "Yuriy Glukhov"
description   = "Upload APK to Google Play"
license       = "MIT"

bin = @["gplay"]

# Dependencies

requires "nim >= 0.17.0"
requires "jwt"
requires "cligen"
