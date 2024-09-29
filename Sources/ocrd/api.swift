import Vapor
import AppKit
import Vision

struct Image: Content {
  let width: UInt32;
  let height: UInt32;
  let content: String;
  let observations: [TextObservation];
}

struct TextObservation: Content {
  let box: Box;
  let content: String;
  let confidence: Float;

  struct Box: Content {
    let x: UInt32;
    let y: UInt32;
    let width: UInt32;
    let height: UInt32;
  }

  init(_ observation: RecognizedTextObservation, _ image: NSImage) {
    let size = image.size;
    let tl = observation.topLeft;
    let br = observation.bottomRight;
    let top = observation.topCandidates(1).first;

    self.content = top?.string ?? "";
    self.confidence = top?.confidence ?? observation.confidence;

    self.box = .init(
      x: UInt32(tl.x * (size.width - 1)),
      y: UInt32((1.0 - tl.y) * (size.height - 1)),
      width: UInt32((br.x - tl.x) * (size.width - 1)),
      height: UInt32((tl.y - br.y) * (size.height - 1))
    );
  }
}

extension Request {
  func json<T>(_ obj: T) throws -> Response where T: Encodable {
    let encoder = JSONEncoder();
    return .init(status: .ok, headers: HTTPHeaders([("content-type", "application/json")]), body: .init(data: try encoder.encode(obj)));
  }
}

enum Mode: String, Content, CaseIterable {
  case fast;
  case accurate;

  var recognitionLevel: RecognizeTextRequest.RecognitionLevel {
    switch self {
      case .fast: return .fast;
      case .accurate: return .accurate;
    }
  }
}

struct Language: Content {
  let inner: Locale.Language;

  init(inner: Locale.Language) {
    self.inner = inner;
  }

  func encode(to e: Encoder) throws {
    var container = e.singleValueContainer();
    try container.encode(inner.minimalIdentifier);
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer();
    self.inner = Locale.Language(identifier: try container.decode(String.self));
  }
}

struct RecognizeTextRevision: Content {
  let inner: RecognizeTextRequest.Revision;

  func encode(to e: Encoder) throws {
    var container = e.singleValueContainer();
    try container.encode(String(describing: inner));
  }

  init(inner: RecognizeTextRequest.Revision) {
    self.inner = inner;
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer();

    let key = try container.decode(String.self);

    for revision in RecognizeTextRequest.supportedRevisions {
      if (String(describing: revision) == key) { self.inner = revision; return; }
    }

    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Revision");
  }
}

struct fetcher {
  static let domains = [
    "i.redd.it",
    "i.imgur.com",
    "pbs.twimg.com",
    "media.tenor.com",
    "cdn.discordapp.com",
    "media.discordapp.net",
    "raw.githubusercontent.com",
    "images-ext-1.discordapp.net",
    "images-ext-2.discordapp.net",
  ];

  static func proxy(app: Application) {
    app.http.client.configuration.proxy = .socksServer(host: "127.1.1.1", port: 9999);

    app.http.client.configuration.networkFrameworkWaitForConnectivity = true;
    app.http.client.configuration.decompression = .enabled(limit: .ratio(10));
    app.http.client.configuration.connectionPool = .init(idleTimeout: .minutes(1));
    app.http.client.configuration.timeout = .init(connect: .seconds(2), read: .minutes(1));
    app.http.client.configuration.redirectConfiguration = .follow(max: 20, allowCycles: false);
  }
}

@main
enum Entrypoint {
  static func main() async throws {
    let api = try await Application.make(.detect());
    let revisions: [RecognizeTextRevision] = RecognizeTextRequest.supportedRevisions.map { .init(inner: $0) };

    fetcher.proxy(app: api);
    api.get { req -> String in return "ok"; };
    api.get("revisions") { req -> [RecognizeTextRevision] in return revisions; };
    api.get("image-types") { req -> Response in return try req.json(NSImage.imageTypes); };

    struct Options: Content {
      let mode: Mode?;
      let words: [String]?;
      let autocorrect: Bool?;
      let languages: [Language]?;
      let detect_language: Bool?;
      let revision: RecognizeTextRevision?;
    }

    enum Result: Content {
      case ok(Image);
      case error(Err);

      struct Err: Content {
        let error: Bool;
        let reason: String;
      }

      func encode(to encoder: Encoder) throws {
        switch self {
          case .ok(let image):
            var container = encoder.singleValueContainer();

            try container.encode(image);

          case .error(let err):
            enum Keys: CodingKey { case error; case reason; }
            var container = encoder.container(keyedBy: Keys.self);

            try container.encode(true, forKey: .error);
            try container.encode(err.reason, forKey: .reason);
        }
      }
    }

    enum ImageSource: Content {
      case url(URL);
      case base64(String);
      case bytes([UInt8]);

      enum CodingKeys: String, CodingKey {
        case url;
        case bytes;
        case base64;
      }

      func encode(to e: Encoder) throws {
        var container = e.container(keyedBy: CodingKeys.self);

        switch self {
          case .url(let url): try container.encode(url, forKey: .url);
          case .bytes(let bytes): try container.encode(bytes, forKey: .bytes);
          case .base64(let base64): try container.encode(base64, forKey: .base64);
        }
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self);

        if let url = try container.decodeIfPresent(URL.self, forKey: .url) { self = .url(url); }
        else if let bytes = try container.decodeIfPresent([UInt8].self, forKey: .bytes) { self = .bytes(bytes); }
        else if let base64 = try container.decodeIfPresent(String.self, forKey: .base64) { self = .base64(base64); }
        else { throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Invalid Image Source"); }
      }
    }

    api.on(.GET, "languages") { req throws -> [Language] in
      let options = try req.query.decode(Options.self);
      let task = RecognizeTextRequest(options.revision?.inner);
      return task.supportedRecognitionLanguages.map { Language(inner: $0) };
    }

    api.on(.POST, body: .collect(maxSize: "24mb")) { req async throws -> Result in
      let options = try req.query.decode(Options.self);

      let ocr = { () -> RecognizeTextRequest in
        var task = RecognizeTextRequest(options.revision?.inner);
        if (nil != options.words) { task.customWords = options.words!; }
        if (nil != options.mode) { task.recognitionLevel = options.mode!.recognitionLevel; }
        if (nil != options.autocorrect) { task.usesLanguageCorrection = options.autocorrect!; }
        if (nil != options.languages) { task.recognitionLanguages = options.languages!.map { $0.inner }; }
        if (nil != options.detect_language) { task.automaticallyDetectsLanguage = options.detect_language!; }

        return task;
      }();

      var image: NSImage;
      var source: ImageSource;

      do {
        source = try req.content.decode(ImageSource.self);
      } catch {
        guard let body = req.body.data else {
          return Result.error(.init(error: true, reason: "Payload Empty"));
        }

        source = .bytes(Array(body.getData(at: body.readerIndex, length: body.readableBytes)!));
      }

      switch source {
        case .bytes(let bytes):
          guard let img = NSImage(data: Data(bytes)) else {
            return Result.error(.init(error: true, reason: "Invalid Image"));
          }; image = img;

        case .base64(let base64):
          guard let data = Data(base64Encoded: base64) else {
            return Result.error(.init(error: true, reason: "Invalid Base64"));
          };

          guard let img = NSImage(data: data) else {
            return Result.error(.init(error: true, reason: "Invalid Image"));
          }; image = img;

        case .url(let url):
          if (fetcher.domains.contains(url.host ?? "")) {
            guard let img = NSImage(contentsOf: url) else {
              return Result.error(.init(error: true, reason: "Invalid Image"));
            }; image = img;
          }

          else {
            guard let res = try? await req.client.get(URI(string: url.absoluteString)) else {
              return Result.error(.init(error: true, reason: "HTTP Error"));
            };

            guard let body = res.body else {
              return Result.error(.init(error: true, reason: "Payload Empty"));
            };

            let data = body.getData(at: body.readerIndex, length: body.readableBytes)!;

            guard let img = NSImage(data: data) else {
              return Result.error(.init(error: true, reason: "Invalid Image"));
            }; image = img;
          }
      }

      guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return Result.error(.init(error: true, reason: "Invalid Image"));
      };

      let observations = try await ocr.perform(on: cg).map { TextObservation($0, image) };

      return Result.ok(.init(
        width: UInt32(image.size.width), height: UInt32(image.size.height),
        content: observations.map { $0.content }.joined(separator: "\n"), observations: observations
      ));
    };

    api.on(.POST, "batch", body: .collect(maxSize: "128mb")) { req async throws -> [Result] in
      let options = try req.query.decode(Options.self);

      let ocr = { () -> RecognizeTextRequest in
        var task = RecognizeTextRequest(options.revision?.inner);
        if (nil != options.words) { task.customWords = options.words!; }
        if (nil != options.mode) { task.recognitionLevel = options.mode!.recognitionLevel; }
        if (nil != options.autocorrect) { task.usesLanguageCorrection = options.autocorrect!; }
        if (nil != options.languages) { task.recognitionLanguages = options.languages!.map { $0.inner }; }
        if (nil != options.detect_language) { task.automaticallyDetectsLanguage = options.detect_language!; }

        return task;
      }();

      let raw = try req.content.decode([ImageSource].self);

      let tasks = raw.map { source in
        return Task {
          var image: NSImage;

          switch source {
            case .bytes(let bytes):
              guard let img = NSImage(data: Data(bytes)) else {
                return Result.error(.init(error: true, reason: "Invalid Image"));
              }; image = img;

            case .base64(let base64):
              guard let data = Data(base64Encoded: base64) else {
                return Result.error(.init(error: true, reason: "Invalid Base64"));
              };

              guard let img = NSImage(data: data) else {
                return Result.error(.init(error: true, reason: "Invalid Image"));
              }; image = img;

            case .url(let url):
              if (fetcher.domains.contains(url.host ?? "")) {
                guard let img = NSImage(contentsOf: url) else {
                  return Result.error(.init(error: true, reason: "Invalid Image"));
                }; image = img;
              }

              else {
                guard let res = try? await req.client.get(URI(string: url.absoluteString)) else {
                  return Result.error(.init(error: true, reason: "HTTP Error"));
                };

                guard let body = res.body else {
                  return Result.error(.init(error: true, reason: "Payload Empty"));
                };

                let data = body.getData(at: body.readerIndex, length: body.readableBytes)!;

                guard let img = NSImage(data: data) else {
                  return Result.error(.init(error: true, reason: "Invalid Image"));
                }; image = img;
            }
          }

          guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Result.error(.init(error: true, reason: "Invalid Image"));
          };

          let observations = try await ocr.perform(on: cg).map { TextObservation($0, image) };

          return Result.ok(.init(
            width: UInt32(image.size.width), height: UInt32(image.size.height),
            content: observations.map { $0.content }.joined(separator: "\n"), observations: observations
          ));
        }
      }

      var observations: [Result] = [];
      for observation in tasks { observations.append(try await observation.value); }

      return observations;
    };

    try await api.execute();
    try await api.asyncShutdown();
  }
}