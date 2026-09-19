#!/usr/bin/env python3
"""Create a minimal Sparkle appcast for a notarized release archive."""
import base64
import datetime
import os
import pathlib
import plistlib
import sys
import urllib.parse
import xml.etree.ElementTree as ET

app, archive, signature_file, output = map(pathlib.Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
signature = ET.fromstring(f'<enclosure xmlns:sparkle="{namespace}" {signature_file.read_text().strip()} />')
signed_value = signature.attrib[f"{{{namespace}}}edSignature"]
if len(base64.b64decode(signed_value, validate=True)) != 64:
    raise SystemExit("Invalid EdDSA signature.")
if int(signature.attrib["length"]) != archive.stat().st_size:
    raise SystemExit("Signed archive length mismatch.")
for key, variable in [("CFBundleShortVersionString", "VERSION"), ("CFBundleVersion", "BUILD_NUMBER"), ("CFBundleIdentifier", "BUNDLE_ID"), ("SUFeedURL", "SU_FEED_URL"), ("SUPublicEDKey", "SU_PUBLIC_ED_KEY")]:
    if info.get(key) != os.environ[variable]:
        raise SystemExit(f"Release metadata mismatch: {key}")
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "WindowZones updates"
ET.SubElement(channel, "link").text = info["SUFeedURL"]
ET.SubElement(channel, "description").text = "WindowZones for Apple silicon"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = "WindowZones " + info["CFBundleShortVersionString"]
for name, value in [("version", info["CFBundleVersion"]), ("shortVersionString", info["CFBundleShortVersionString"]), ("minimumSystemVersion", "15.0.0"), ("hardwareRequirements", "arm64")]:
    ET.SubElement(item, f"{{{namespace}}}{name}").text = value
ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
url = os.environ["DOWNLOAD_BASE_URL"].rstrip("/") + "/" + urllib.parse.quote(archive.name)
if urllib.parse.urlsplit(url).scheme != "https":
    raise SystemExit("HTTPS download URL required.")
signature.set("url", url)
signature.set("type", "application/octet-stream")
item.append(signature)
ET.indent(rss)
ET.ElementTree(rss).write(output, encoding="utf-8", xml_declaration=True)
