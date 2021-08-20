import json, times, httpclient, cgi, os
import jwt

################################################################################
# REST Helpers

type
    RestObjBase* = ref object of RootObj
        url*: string
    RestObj*[T] = ref object of RestObjBase
        parent*: T
    RestApi* = ref object of RestObjBase
        mClient: HttpClient

template rootResource[T: RestObjBase](r: T): auto =
    when compiles(r.parent):
        r.parent.rootResource
    else:
        r

template client[T: RestObjBase](r: T): HttpClient = r.rootResource.mClient

template fullUrl[T: RestObjBase](r: T): string =
    when compiles(r.mClient):
        r.url
    else:
        r.parent.fullUrl & "/" & r.url

template urlWithoutEndpoint[T: RestObjBase](r: T): string =
    when compiles(r.parent.mClient):
        r.url
    else:
        r.parent.urlWithoutEndpoint & "/" & r.url

proc request(cl: HttpClient, meth, url: string, body: string, contentType: string = ""): JsonNode =
    cl.headers["Content-Length"] = $body.len
    if body.len == 0:
        cl.headers.del("Content-Type")
    else:
        if contentType.len != 0:
            cl.headers["Content-Type"] = contentType
        else:
            cl.headers["Content-Type"] = "application/octet-stream"

    let resp = httpclient.request(cl, url, meth, body)
    try:
        result = parseJson(resp.body)
    except:
        echo "Error parsing response: ", resp.body

    if resp.code.is4xx or resp.code.is5xx:
        var msg = resp.status
        if resp.body.len != 0:
            msg &= ":\l" & resp.body
        raise newException(HttpRequestError, msg)

proc request(cl: HttpClient, meth, url: string, body: JsonNode, contentType: string = ""): JsonNode =
    var ct = contentType
    if ct.len == 0:
        ct = "application/json"
    request(cl, meth, url, $body, ct)

proc request[R: RestObjBase, T](res: R, meth, url: string, body: T, contentType: string = ""): JsonNode =
    res.client.request(meth, res.fullUrl & "/" & url, body, contentType)

proc postAux[T](cl: HttpClient | RestObjBase, url: string, body: T, contentType: string): JsonNode =
    cl.request("POST", url, body, contentType)

proc post[T](cl: HttpClient | RestObjBase, url: string, body: T, contentType: string = ""): JsonNode =
    postAux(cl, url, body, contentType)

proc post(cl: HttpClient | RestObjBase, url: string): JsonNode =
    postAux(cl, url, "", "")

proc put[T](cl: HttpClient | RestObjBase, url: string, body: T = "", contentType: string = ""): JsonNode =
    cl.request("PUT", url, body, contentType)

proc get[T](cl: HttpClient | RestObjBase, url: string, body: T = "", contentType: string = ""): JsonNode =
    cl.request("GET", url, body, contentType)

################################################################################
# Google play publisher API

type
  GooglePlayPublisherAPI* = ref object of RestApi

  Application* = ref object of RestObj[GooglePlayPublisherAPI]
  Edit* = ref object of RestObj[Application]
  Track* = ref object of RestObj[Edit]

proc newGooglePlayPublisherAPI*(email, privkey: string): GooglePlayPublisherAPI =
    result.new()

    result.url = "https://www.googleapis.com/androidpublisher/v3"
    let authUrl = "https://www.googleapis.com/oauth2/v4/token"

    var tok = JWT(
        header: JOSEHeader(alg: RS256, typ: "JWT"),
        claims: toClaims(%*{
        "iss": email,
        "scope": "https://www.googleapis.com/auth/androidpublisher",
        "aud": authUrl,
        "exp": int(epochTime() + 60 * 60),
        "iat": int(epochTime())
    }))

    tok.sign(privkey)

    let postdata = "grant_type=" & encodeUrl("urn:ietf:params:oauth:grant-type:jwt-bearer") & "&assertion=" & $tok
    result.mClient = newHttpClient()
    result.mClient.headers = newHttpHeaders({ "Content-Length": $postdata.len, "Content-Type": "application/x-www-form-urlencoded" })
    let r = result.mClient.postContent(authUrl, postdata).parseJson()
    let accessToken = r["access_token"].str
    result.mClient.headers["Authorization"] = "Bearer " & accessToken

proc application*(r: GooglePlayPublisherAPI, id: string): Application = Application(parent: r, url: "applications/" & id)

proc newEdit*(r: Application): Edit =
    let b = %*{ "expiryTimeSeconds": $int(epochTime() + 60 * 60) }
    result = Edit(parent: r, url: "edits/" & r.post("edits", b)["id"].str)

proc commit*(r: Edit) = discard r.client.post(r.fullUrl & ":commit")

proc uploadApk*(e: Edit, path: string): JsonNode =
    let url = "https://www.googleapis.com/upload/androidpublisher/v3/" & e.urlWithoutEndpoint & "/apks?uploadType=media"
    let content = readFile(path)
    e.client.post(url, content, "application/vnd.android.package-archive")

proc uploadAab*(e: Edit, path: string): JsonNode =
    let url = "https://www.googleapis.com/upload/androidpublisher/v3/" & e.urlWithoutEndpoint & "/bundles?uploadType=media"
    let content = readFile(path)
    e.client.post(url, content, "application/vnd.android.package-archive")


proc track*(e: Edit, name: string): Track = Track(parent: e, url: "tracks/" & name)
proc update*(t: Track, versionCode: int) = discard t.client.put(t.fullUrl, %*{"releases": [{"status": "completed", "versionCodes": [versionCode]}]})

################################################################################
# Uploader
when isMainModule:
    import os
    import cligen

    proc upload(email: string = "", key: string = "", apkId, track, apk: string, useAAB: bool = false): int =
        var email = email
        var key = key
        if email.len == 0: email = getEnv("GPLAY_EMAIL")
        if key.len == 0: key = getEnv("GPLAY_KEY")
        var fail = false
        if email.len == 0:
            echo "Error: no email provided. Use --email argument or GPLAY_EMAIL environment variable"
            fail = true

        if key.len == 0:
            echo "Error: no private key path provided. Use --key argument or GPLAY_KEY environment variable"
            fail = true

        if track.len == 0:
            echo "Error: no track provided"
            fail = true

        if apk.len == 0:
            echo "Error: no apk provided"
            fail = true

        if apkId.len == 0:
            echo "Error: no apk id provided"
            fail = true

        if fail: return 1

        let keyContent = readFile(key)
        let api = newGooglePlayPublisherAPI(email, keyContent)
        let app = api.application(apkId)
        let edit = app.newEdit()
        echo "Uploading apk: ", apk
        var appVersion = 0
        if useAAB:
            appVersion = edit.uploadAab(apk)["versionCode"].num.int
        else:
            appVersion = edit.uploadApk(apk)["versionCode"].num.int
        let tr = edit.track(track)
        echo "Setting track ", track, " to version ", appVersion
        tr.update(appVersion)
        echo "Committing"
        edit.commit()

    dispatchMulti([upload])
# gplay upload --apkId=com.oftengames.game2 --track=alpha --apk==build\outputs\bundle\release\com.oftengames.game2-release.aab --useAAB=true