#!/usr/bin/env python3
"""Turns NIST CAVP and Wycheproof downloads into tests/vectors/crypto/*.txt.

A one-off, rerun only to refresh the vectors (see tests/vectors/crypto/README.md):

    convert-vectors.py <downloads> <output>

Each output line is a record: a kind and its fields, space-separated, in hexadecimal,
with "-" for an empty field. Keys in these files are the published test keys.
"""
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])


def field(value):
    return value if value else "-"


def rsp(path):
    """The records of a .rsp file, each a dict with its [K = V] headers. A blank line ends one."""
    headers, record, records = {}, {}, []
    for line in path.read_text().splitlines() + [""]:
        line = line.strip()
        if not line:
            if record:
                records.append((dict(headers), record))
                record = {}
        elif line.startswith("[") and line.endswith("]"):
            inside = line[1:-1]
            if inside in ("ENCRYPT", "DECRYPT"):
                headers.pop("ENCRYPT", None)
                headers.pop("DECRYPT", None)
                headers[inside] = ""
            elif "=" in inside:
                key, value = inside.split("=", 1)
                headers[key.strip()] = value.strip()
        elif line == "FAIL":
            record["FAIL"] = "1"
        elif "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            record[key.strip()] = value.strip()
    return records


def hashes():
    lines = []
    base = source / "x-shabytetestvectors" / "shabytetestvectors"
    for name, tag in (("SHA1", "sha1"), ("SHA256", "sha256"), ("SHA384", "sha384"), ("SHA512", "sha512")):
        for _, record in rsp(base / f"{name}ShortMsg.rsp"):
            message = record["Msg"] if record["Len"] != "0" else ""
            lines.append(f"{tag} {field(message)} {record['MD']}")
        for index, (_, record) in enumerate(rsp(base / f"{name}LongMsg.rsp")):
            # The long messages are large; every tenth still covers multi-block padding.
            if index % 10 == 0:
                lines.append(f"{tag} {record['Msg']} {record['MD']}")
    return lines


def hmacs():
    lines = []
    sizes = {"20": "sha1", "32": "sha256", "48": "sha384", "64": "sha512"}
    for index, (headers, record) in enumerate(rsp(source / "x-hmactestvectors" / "HMAC.rsp")):
        tag = sizes.get(headers.get("L", ""))
        if tag and index % 3 == 0:
            lines.append(f"hmac {tag} {record['Key']} {record['Msg']} {record['Mac']} valid")
    for tag in ("sha1", "sha256", "sha384", "sha512"):
        data = json.loads((source / f"hmac_{tag}_test.json").read_text())
        for group in data["testGroups"]:
            for test in group["tests"]:
                lines.append(
                    f"hmac {tag} {field(test['key'])} {field(test['msg'])} {field(test['tag'])} {test['result']}"
                )
    return lines


def aes_block():
    lines = []
    files = sorted((source / "x-KAT_AES").glob("*.rsp")) + sorted((source / "x-aesmmt").glob("*.rsp"))
    for path in files:
        match = re.match(r"(ECB|CBC)", path.name)
        if not match:
            continue
        mode = match.group(1).lower()
        for headers, record in rsp(path):
            direction = "e" if "ENCRYPT" in headers else "d"
            lines.append(
                f"{mode} {direction} {record['KEY']} {field(record.get('IV', ''))} {record['PLAINTEXT']} {record['CIPHERTEXT']}"
                if "PLAINTEXT" in record and "CIPHERTEXT" in record else ""
            )
    data = json.loads((source / "aes_cbc_pkcs5_test.json").read_text())
    for group in data["testGroups"]:
        for test in group["tests"]:
            lines.append(
                f"cbc-pkcs7 {test['key']} {test['iv']} {field(test['msg'])} {field(test['ct'])} {test['result']}"
            )
    return [line for line in lines if line]


def gcm():
    lines = []
    for bits in ("128", "192", "256"):
        for name in (f"gcmEncryptExtIV{bits}.rsp", f"gcmDecrypt{bits}.rsp"):
            kept = 0
            for headers, record in rsp(source / "x-gcmtestvectors" / name):
                # This API has 96-bit nonces and 128-bit tags. A third keeps the file small.
                if headers.get("IVlen") != "96" or headers.get("Taglen") != "128":
                    continue
                kept += 1
                if kept % 3:
                    continue
                result = "invalid" if "FAIL" in record else "valid"
                lines.append(
                    f"gcm {record['Key']} {record['IV']} {field(record.get('PT', ''))} {field(record.get('AAD', ''))} "
                    f"{field(record.get('CT', ''))} {record['Tag']} {result}"
                )
    data = json.loads((source / "aes_gcm_test.json").read_text())
    for group in data["testGroups"]:
        if group["ivSize"] != 96 or group["tagSize"] != 128:
            continue
        for test in group["tests"]:
            lines.append(
                f"gcm {test['key']} {test['iv']} {field(test['msg'])} {field(test['aad'])} "
                f"{field(test['ct'])} {test['tag']} {test['result']}"
            )
    return lines


def rsa():
    lines = []
    data = json.loads((source / "rsa_pkcs1_1024_sig_gen_test.json").read_text())
    for group in data["testGroups"]:
        if group["sha"] != "SHA-1":
            continue
        lines.append(f"key {group['privateKeyPkcs8']} {group['keyDer']}")
        for test in group["tests"]:
            lines.append(f"sign-sha1 {field(test['msg'])} {test['sig']} {test['result']}")
    data = json.loads((source / "rsa_pkcs1_2048_sig_gen_test.json").read_text())
    for group in data["testGroups"]:
        if group["sha"] != "SHA-256":
            continue
        lines.append(f"key {group['privateKeyPkcs8']} {group['keyDer']}")
        for test in group["tests"]:
            lines.append(f"sign-sha256 {field(test['msg'])} {test['sig']} {test['result']}")
    data = json.loads((source / "rsa_signature_2048_sha256_test.json").read_text())
    for group in data["testGroups"]:
        lines.append(f"public {group['publicKeyDer']}")
        for test in group["tests"]:
            lines.append(f"verify-sha256 {field(test['msg'])} {field(test['sig'])} {test['result']}")
    data = json.loads((source / "rsa_pkcs1_2048_test.json").read_text())
    for group in data["testGroups"]:
        lines.append(f"private {group['privateKeyPkcs8']}")
        for test in group["tests"]:
            lines.append(f"decrypt-pkcs1 {field(test['msg'])} {field(test['ct'])} {test['result']}")
    for name, kind in (
        ("rsa_oaep_2048_sha256_mgf1sha256_test.json", "decrypt-oaep-sha256"),
        ("rsa_oaep_2048_sha1_mgf1sha1_test.json", "decrypt-oaep-sha1"),
    ):
        data = json.loads((source / name).read_text())
        for group in data["testGroups"]:
            lines.append(f"private {group['privateKeyPkcs8']}")
            for test in group["tests"]:
                # There is no label parameter in this API.
                if test["label"]:
                    continue
                lines.append(f"{kind} {field(test['msg'])} {field(test['ct'])} {test['result']}")
    return lines


output.mkdir(parents=True, exist_ok=True)
for name, make in (("sha", hashes), ("hmac", hmacs), ("aes-block", aes_block), ("aes-gcm", gcm), ("rsa", rsa)):
    lines = make()
    (output / f"{name}.txt").write_text("\n".join(lines) + "\n")
    print(name, len(lines))
