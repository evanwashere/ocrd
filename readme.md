<h1 align=center>ocrd(-aemon)</h1>
<div align=center>self-hostable ocr api for macos</div>
<br />

### Install

`git clone https://github.com/evanwashere/ocrd.git`

### Build

`swift run -c release`
`swift build -c release`

## Recommendations
- comment or configure proxy in `Sources/ocrd/api.swift:118`
- add trusted domains to domains list in `Sources/ocrd/api.swift:105`
- example proxy setup – [wireproxy](https://github.com/pufferffish/wireproxy) + dedicated ip/server for untrusted domains traffic

## Command Line Usage

### `ocrd -h`

```swift
Usage: ocrd <command>

Commands:
  routes Displays all registered routes.
   serve Begins serving the app over HTTP.
```

### `ocrd serve`

```swift
Usage: ocrd serve [--hostname,-H] [--port,-p] [--bind,-b] [--unix-socket] 

Begins serving the app over HTTP.

Options:
     hostname Set the hostname the server will run on.
         port Set the port the server will run on.
         bind Convenience for setting hostname and port together.
  unix-socket Set the path for the unix domain socket file the server will bind to.
```

## API docs

### `GET /` -> `"ok"`
health check endpoint

### `GET /revisions` -> `str[]`
lists ocr engine revisions

### `GET /image-types` -> `str[]`
lists image types supported by api

### `GET /languages` -> `str[]`
lists languages supported by the ocr engine

### `POST /` -> `Result`
do ocr on a single image

#### body:
- json <- `ImageSource`
- bytes <- raw image bytes

#### query params (optional):
- `words` <- `str[]`
- `revision` <- `string`
- `languages` <- `str[]`
- `autocorrect` <- `bool`
- `mode` <- `fast | accurate`
- `detect_language` <- `bool`

detailed description of each parameter can be found in [Apple API Docs](https://developer.apple.com/documentation/vision/recognizetextrequest#Inspecting-a-request)

### `POST /batch` -> `Result[]`

#### body:
- json <- `ImageSource[]`

#### query params (optional):
- `words` <- `str[]`
- `revision` <- `string`
- `languages` <- `str[]`
- `autocorrect` <- `bool`
- `mode` <- `fast | accurate`
- `detect_language` <- `bool`

detailed description of each parameter can be found in [Apple API Docs](https://developer.apple.com/documentation/vision/recognizetextrequest#Inspecting-a-request)

## API Types

### `ImageSource`
```typescript
type ImageSource =
  { url: string; }
  | { base64: string; }
  | { bytes: number[]; }
```

### `Result`
```typescript
type Result = Ok | Err;

type Err = {
  error: bool;
  reason: string;
}

type Ok = {
  width: number;
  height: number;
  content: string;
  observations: TextObservation[];
}

type TextObservation = {
  box: Box;
  content: string;
  confidence: number;
}

type Box = {
  x: number;
  y: number;
  width: number;
  height: number;
}
```


## License

Apache 2.0 © [Evan](https://github.com/evanwashere)