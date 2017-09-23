# gplay [![Build Status](https://travis-ci.org/yglukhov/gplay.svg?branch=master)](https://travis-ci.org/yglukhov/gplay)
Google Play APK Uploader, written in [Nim](https://nim-lang.org)

## Usage
Uploading:
```sh
gplay upload --email=<GPLAY_EMAIL> --key=<PATH_TO_GPLAY_PRIVATE_KEY> <APP_ID> <TRACK_NAME> <PATH_TO_APK>
```
Example:
```sh
gplay upload --email=my-buildmachine@api-1234567-1234567.iam.gserviceaccount.com --key=path/to/private.key com.cmycompany.myapp alpha path/to/myapp.apk
```
