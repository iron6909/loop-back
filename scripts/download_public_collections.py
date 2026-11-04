"""下载原 App 匿名合集及字幕；只用标准库，不读取登录凭据。"""

import argparse
import concurrent.futures
import hashlib
import json
import math
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://www.echo-loop.top"
DEFAULT_DEST = Path(__file__).resolve().parents[1] / "resources/public_collections"


def request(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username:
        raise ValueError("Expected a public HTTPS URL")
    return urllib.request.urlopen(  # noqa: S310 — 上方已拒绝非 HTTPS 地址。
        urllib.request.Request(url, headers={"User-Agent": "EchoLoop-PublicArchive/1.0"}),  # noqa: S310
        timeout=45,
    )


def fetch_json(url):
    for attempt in range(3):
        try:
            with request(url) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code not in (408, 429, 500, 502, 503, 504) or attempt == 2:
                raise
        except (OSError, ValueError):
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)
    raise RuntimeError("JSON request exhausted retries")


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def pages(endpoint):
    cursor = None
    seen = set()
    while True:
        url = endpoint + ("?" + urllib.parse.urlencode({"cursor": cursor}) if cursor else "")
        page = fetch_json(url)
        if not isinstance(page.get("items"), list):
            raise ValueError("Missing page items")
        yield page
        cursor = page.get("nextCursor")
        if not cursor:
            break
        if not isinstance(cursor, str) or cursor in seen:
            raise ValueError("Invalid or repeated pagination cursor")
        seen.add(cursor)


def safe_name(value):
    return re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")[:90] or "untitled"


def timestamp(seconds):
    if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
        raise ValueError("Invalid subtitle timestamp")
    total = round(seconds * 1000)
    hours, total = divmod(total, 3600000)
    minutes, total = divmod(total, 60000)
    secs, millis = divmod(total, 1000)
    return f"{hours:02}:{minutes:02}:{secs:02},{millis:03}"


def subtitle_srt(subtitle):
    rows = []
    for index, sentence in enumerate(subtitle["sentences"], 1):
        start, end = sentence["startTime"], sentence["endTime"]
        if end < start or not isinstance(sentence["text"], str):
            raise ValueError("Invalid subtitle sentence")
        rows.append(f"{index}\n{timestamp(start)} --> {timestamp(end)}\n{sentence['text'].strip()}\n")
    return "\n".join(rows)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(url, path, previous=None):
    # 已完成资源按大小和 SHA-256 验证后复用；失败文件保持 .part，绝不当成成品。
    if (previous and previous.get("source") == url and path.is_file()
            and path.stat().st_size == previous.get("bytes")
            and digest(path) == previous.get("sha256")):
        return previous
    temporary = path.with_suffix(path.suffix + ".part")
    for attempt in range(3):
        try:
            with request(url) as response, temporary.open("wb") as output:
                if response.headers.get_content_type() in ("text/html", "application/json"):
                    raise ValueError("Media endpoint returned a document")
                expected = response.headers.get("Content-Length")
                checksum = hashlib.sha256()
                count = 0
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    checksum.update(chunk)
                    count += len(chunk)
                if count == 0 or (expected is not None and count != int(expected)):
                    raise ValueError("Incomplete response body")
            temporary.replace(path)
            return {"source": url, "path": path.name, "bytes": count, "sha256": checksum.hexdigest()}
        except urllib.error.HTTPError as error:
            if error.code in (401, 403, 404) or attempt == 2:
                raise
        except (OSError, ValueError):
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)
    raise RuntimeError("Media request exhausted retries")


def archive_file(collection_id, item, index, directory, previous):
    file_id = item["id"]
    endpoint = f"{BASE}/api/v2/collections/{urllib.parse.quote(collection_id, safe='')}/files/{urllib.parse.quote(file_id, safe='')}"
    source = item["mediaUrl"]
    suffix = Path(urllib.parse.urlsplit(source).path).suffix.lower()
    if not re.fullmatch(r"\.[a-z0-9]{1,8}", suffix):
        raise ValueError("Invalid media extension")
    stem = f"{index:04}-{safe_name(item['title'])}-{file_id[:8]}"
    result = {"id": file_id, "title": item["title"], "metadataUrl": endpoint, "status": "failed"}
    try:
        result["media"] = download(source, directory / (stem + suffix), previous.get("media"))
        detail_path = directory / "metadata" / (file_id + ".json")
        if detail_path.exists():
            detail = json.loads(detail_path.read_text(encoding="utf-8"))
        else:
            detail = fetch_json(endpoint)
            save_json(detail_path, detail)
        srt = subtitle_srt(detail["subtitle"])
        if srt:
            (directory / (stem + ".srt")).write_text(srt, encoding="utf-8")
            result["subtitle"] = stem + ".srt"
        result["status"] = "complete"
    except urllib.error.HTTPError as error:
        result["error"] = f"HTTP {error.code}"
        result["status"] = "restricted" if error.code in (401, 403) else "failed"
    except (OSError, ValueError, KeyError) as error:
        result["error"] = type(error).__name__
    return result


def run(destination, workers):
    destination.mkdir(parents=True, exist_ok=True)
    catalog = [item for page in pages(BASE + "/api/v2/collections") for item in page["items"]]
    if len({item["id"] for item in catalog}) != len(catalog):
        raise ValueError("Duplicate collection IDs")
    save_json(destination / "catalog.json", {"source": BASE + "/api/v2/collections", "items": catalog})
    summary = {"source": BASE, "collections": [], "files": 0, "complete": 0, "bytes": 0}
    for collection in catalog:
        collection_id = collection["id"]
        directory = destination / (safe_name(collection["name"]) + "-" + collection_id[:8])
        directory.mkdir(exist_ok=True)
        endpoint = BASE + "/api/v2/collections/" + urllib.parse.quote(collection_id, safe="")
        items = [item for page in pages(endpoint) for item in page["items"]]
        if len({item["id"] for item in items}) != len(items) or len(items) != collection["fileCount"]:
            raise ValueError("Collection page count changed; rerun to refresh")
        save_json(directory / "collection.json", {"source": endpoint, "collection": collection, "items": items})
        manifest_path = directory / "manifest.json"
        old = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {"files": []}
        previous = {item["id"]: item for item in old["files"]}
        results = {}
        print(f"START {collection['name']} files={len(items)}", flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(archive_file, collection_id, item, index, directory, previous.get(item["id"], {})) for index, item in enumerate(items, 1)]
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results[result["id"]] = result
                save_json(manifest_path, {"collection": collection, "files": [results[item["id"]] for item in items if item["id"] in results]})
                if result["status"] != "complete":
                    print(f"ISSUE {collection['name']} {result['id']} {result.get('error')}", flush=True)
                elif len(results) % 10 == 0:
                    print(f"PROGRESS {collection['name']} {len(results)}/{len(items)}", flush=True)
        complete = sum(result["status"] == "complete" for result in results.values())
        size = sum(result.get("media", {}).get("bytes", 0) for result in results.values())
        summary["collections"].append({"id": collection_id, "name": collection["name"], "path": directory.name, "files": len(items), "complete": complete, "bytes": size})
        summary["files"] += len(items)
        summary["complete"] += complete
        summary["bytes"] += size
        save_json(destination / "manifest.json", summary)
        print(f"DONE {collection['name']} complete={complete}/{len(items)} bytes={size}", flush=True)
    return 0 if summary["complete"] == summary["files"] else 1


def verify(destination):
    summary = json.loads((destination / "manifest.json").read_text(encoding="utf-8"))
    catalog = json.loads((destination / "catalog.json").read_text(encoding="utf-8"))["items"]
    if {item["id"] for item in catalog} != {item["id"] for item in summary["collections"]}:
        raise ValueError("Incomplete collection list")
    count, size = 0, 0
    for collection in summary["collections"]:
        directory = destination / collection["path"]
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
        source = json.loads((directory / "collection.json").read_text(encoding="utf-8"))
        if {item["id"] for item in source["items"]} != {item["id"] for item in manifest["files"]}:
            raise ValueError("Incomplete collection files")
        for item in manifest["files"]:
            if item["status"] != "complete":
                raise ValueError("Unfinished file: " + item["id"])
            media = item["media"]
            path = directory / media["path"]
            if path.stat().st_size != media["bytes"] or digest(path) != media["sha256"]:
                raise ValueError("Media integrity mismatch: " + item["id"])
            detail = json.loads((directory / "metadata" / (item["id"] + ".json")).read_text(encoding="utf-8"))
            expected_srt = subtitle_srt(detail["subtitle"])
            if expected_srt and (directory / item["subtitle"]).read_text(encoding="utf-8") != expected_srt:
                raise ValueError("Subtitle mismatch: " + item["id"])
            count += 1
            size += media["bytes"]
    if count != summary["files"] or count != summary["complete"] or size != summary["bytes"]:
        raise ValueError("Archive totals mismatch")
    if list(destination.rglob("*.part")):
        raise ValueError("Incomplete temporary files remain")
    print(f"Verified {len(catalog)} collections, {count} files, {size} bytes; SHA-256 and subtitles match")


def check():
    assert timestamp(3661.234) == "01:01:01,234"
    assert timestamp(59.9999) == "00:01:00,000"
    assert safe_name('../a:b/c') == '_a_b_c'
    assert subtitle_srt({"sentences": [{"text": "Hello", "startTime": 0.78, "endTime": 2.6399999}]}) == "1\n00:00:00,780 --> 00:00:02,640\nHello\n"
    for invalid in (-1, float("nan")):
        try:
            timestamp(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid timestamp accepted")
    print("Self-check passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=DEFAULT_DEST)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=3)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.check:
        check()
    elif args.verify:
        verify(args.destination)
    else:
        raise SystemExit(run(args.destination, args.workers))
