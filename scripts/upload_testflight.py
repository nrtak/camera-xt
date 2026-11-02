"""Upload the exported app and require an explicit Apple success receipt."""

import os
from pathlib import Path
import subprocess
import sys


def exported_ipa(directory):
    files = sorted(Path(directory).glob("*.ipa"))
    if len(files) != 1 or not files[0].is_file() or files[0].stat().st_size == 0:
        raise RuntimeError("Expected exactly one nonempty exported IPA.")
    return files[0]


def upload(directory, key_id, issuer_id):
    ipa = exported_ipa(directory)
    result = subprocess.run(
        ["xcrun", "altool", "--upload-app", "--type", "ios", "--file", str(ipa),
         "--apiKey", key_id, "--apiIssuer", issuer_id],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
    )
    output = result.stdout or ""
    print(output, end="" if output.endswith("\n") else "\n", flush=True)
    if result.returncode != 0:
        raise RuntimeError("Apple upload command failed.")
    if not any(receipt in output for receipt in (
        "UPLOAD SUCCEEDED with no errors", "No errors uploading archive at",
    )):
        raise RuntimeError("Apple upload did not provide a success receipt.")


if __name__ == "__main__":
    try:
        upload("build/export", os.environ["APP_STORE_CONNECT_KEY_ID"],
               os.environ["APP_STORE_CONNECT_ISSUER_ID"])
    except (OSError, RuntimeError, KeyError) as error:
        print(f"TestFlight upload failed: {error}", file=sys.stderr)
        sys.exit(1)
