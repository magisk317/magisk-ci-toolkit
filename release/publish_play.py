#!/usr/bin/env python3
"""
Lightweight, native Python Google Play upload client.
Uploads Android App Bundles (.aab), mapping.txt, release notes, and updates tracks
directly via the Google Play Developer API v3 using Service Account OAuth JWT.
Zero third-party pip dependencies; runs directly in alpine/utility containers.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def get_access_token(service_account_json: dict) -> str:
    client_email = service_account_json["client_email"]
    private_key_pem = service_account_json["private_key"]

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": client_email,
        "scope": "https://www.googleapis.com/auth/androidpublisher",
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
    }

    unsigned_token = (
        f"{base64url(json.dumps(header).encode('utf-8'))}."
        f"{base64url(json.dumps(claims).encode('utf-8'))}"
    )

    # Sign using openssl (always present in utility/alpine/debian images)
    import tempfile
    with tempfile.NamedTemporaryFile("w", delete=False) as key_file:
        key_file.write(private_key_pem)
        key_path = key_file.name

    try:
        proc = subprocess.Popen(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        sig_raw, err = proc.communicate(input=unsigned_token.encode("utf-8"))
        if proc.returncode != 0:
            raise RuntimeError(f"openssl signing failed: {err.decode('utf-8')}")
    finally:
        if os.path.exists(key_path):
            os.unlink(key_path)

    signed_jwt = f"{unsigned_token}.{base64url(sig_raw)}"

    token_url = "https://oauth2.googleapis.com/token"
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": signed_jwt,
    }).encode("utf-8")

    req = urllib.request.Request(token_url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        res = json.loads(resp.read().decode("utf-8"))
        return res["access_token"]


def api_request(
    url: str,
    token: str,
    method: str = "GET",
    data: bytes = None,
    content_type: str = "application/json",
) -> dict:
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if content_type:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=180) as resp:
        content = resp.read()
        if content:
            return json.loads(content.decode("utf-8"))
        return {}


def main():
    parser = argparse.ArgumentParser(description="Upload AAB to Google Play Developer API v3")
    parser.add_argument("--credentials", required=True, help="Path to Service Account JSON credentials")
    parser.add_argument("--package-name", required=True, help="Application Package Name")
    parser.add_argument("--aab", required=True, help="Path to .aab file")
    parser.add_argument("--track", required=True, help="Target Play Track (production, beta, alpha, internal)")
    parser.add_argument("--version-code", type=int, required=True, help="Version code of the AAB")
    parser.add_argument("--version-name", required=True, help="Version name of the release")
    parser.add_argument("--mapping", help="Optional path to Proguard mapping.txt")
    parser.add_argument("--native-symbols", help="Optional path to native-debug-symbols.zip")
    parser.add_argument("--metadata-dir", help="Optional path to fastlane/metadata directory")
    args = parser.parse_args()

    if not os.path.isfile(args.aab):
        sys.exit(f"ERROR: AAB file not found: {args.aab}")

    with open(args.credentials, "r", encoding="utf-8") as f:
        sa_info = json.load(f)

    print(f"Obtaining Google Play OAuth token for {sa_info.get('client_email')}...")
    access_token = get_access_token(sa_info)

    api_base = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{args.package_name}"

    print(f"Creating new edit transaction for {args.package_name}...")
    edit_info = api_request(f"{api_base}/edits", access_token, method="POST", data=b"{}")
    edit_id = edit_info["id"]
    print(f"Edit ID created: {edit_id}")

    try:
        # 1. Upload AAB
        aab_size = os.path.getsize(args.aab)
        print(f"Uploading AAB ({aab_size / (1024*1024):.2f} MB)...")
        upload_url = (
            f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"
            f"{args.package_name}/edits/{edit_id}/bundles?uploadType=media"
        )
        with open(args.aab, "rb") as f:
            aab_bytes = f.read()

        bundle_resp = api_request(
            upload_url,
            access_token,
            method="POST",
            data=aab_bytes,
            content_type="application/octet-stream",
        )
        uploaded_version_code = int(bundle_resp.get("versionCode", args.version_code))
        print(f"AAB uploaded successfully: versionCode={uploaded_version_code}")

        # 2. Upload Mapping / Deobfuscation File if present
        if args.mapping and os.path.isfile(args.mapping):
            map_size = os.path.getsize(args.mapping)
            print(f"Uploading mapping.txt ({map_size / 1024:.1f} KB)...")
            map_upload_url = (
                f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"
                f"{args.package_name}/edits/{edit_id}/apks/{uploaded_version_code}/deobfuscationFiles/proguard?uploadType=media"
            )
            with open(args.mapping, "rb") as f:
                map_bytes = f.read()
            api_request(
                map_upload_url,
                access_token,
                method="POST",
                data=map_bytes,
                content_type="application/octet-stream",
            )
            print("Mapping file uploaded successfully.")

        # 2b. Upload native debug symbols if present
        if args.native_symbols and os.path.isfile(args.native_symbols):
            sym_size = os.path.getsize(args.native_symbols)
            print(f"Uploading native-debug-symbols.zip ({sym_size / 1024:.1f} KB)...")
            sym_upload_url = (
                f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"
                f"{args.package_name}/edits/{edit_id}/apks/{uploaded_version_code}/deobfuscationFiles/nativeDebugSymbols?uploadType=media"
            )
            with open(args.native_symbols, "rb") as f:
                sym_bytes = f.read()
            api_request(
                sym_upload_url,
                access_token,
                method="POST",
                data=sym_bytes,
                content_type="application/octet-stream",
            )
            print("Native debug symbols uploaded successfully.")

        # 3. Read Release Notes if metadata dir is present
        release_notes = []
        if args.metadata_dir and os.path.isdir(args.metadata_dir):
            for root, _, files in os.walk(args.metadata_dir):
                if os.path.basename(root) == "changelogs":
                    locale = os.path.basename(os.path.dirname(root))
                    # check for <versionCode>.txt or default.txt
                    for candidate in [f"{args.version_code}.txt", f"{uploaded_version_code}.txt", "default.txt"]:
                        p = os.path.join(root, candidate)
                        if os.path.isfile(p):
                            try:
                                with open(p, "r", encoding="utf-8") as f:
                                    note_text = f.read().strip()
                                    if note_text:
                                        release_notes.append({"language": locale, "text": note_text[:500]})
                                        break
                            except Exception:
                                pass

        # 4. Assign Track and Release Status
        print(f"Assigning release to track '{args.track}'...")
        track_url = f"{api_base}/edits/{edit_id}/tracks/{args.track}"
        track_body = {
            "track": args.track,
            "releases": [
                {
                    "name": args.version_name,
                    "versionCodes": [str(uploaded_version_code)],
                    "status": "completed",
                    "releaseNotes": release_notes,
                }
            ],
        }
        api_request(
            track_url,
            access_token,
            method="PUT",
            data=json.dumps(track_body).encode("utf-8"),
        )
        print(f"Track '{args.track}' updated with release {args.version_name} ({uploaded_version_code}).")

        # 5. Commit Edit
        print(f"Committing edit {edit_id}...")
        commit_url = f"{api_base}/edits/{edit_id}:commit"
        commit_resp = api_request(commit_url, access_token, method="POST", data=b"{}")
        print(f"Edit {edit_id} successfully committed! Release is live on track '{args.track}'.")

    except Exception as e:
        print(f"ERROR: Play upload failed: {e}", file=sys.stderr)
        try:
            # Delete/abort edit on failure
            api_request(f"{api_base}/edits/{edit_id}", access_token, method="DELETE", content_type=None)
        except Exception:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
