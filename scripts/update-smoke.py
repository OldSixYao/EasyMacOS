#!/usr/bin/env python3
"""使用临时更新源和唯一应用标识验证实际升级；不会启动正式应用或触碰真实历史。"""
import base64
import functools
import hashlib
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def read_info(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        return plistlib.load(source)


def write_info(app, info):
    with (app / 'Contents/Info.plist').open('wb') as target:
        plistlib.dump(info, target)


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main():
    os.chdir(ROOT)
    source = ROOT / 'dist/EasyMacOS.app'
    if not source.is_dir():
        raise SystemExit('请先运行 ./scripts/build.sh。')
    identity = os.environ.get('SIGNING_IDENTITY') or os.environ.get('DEVELOPER_ID_APPLICATION')
    if not identity:
        identity = (pathlib.Path.home() / 'Library/Application Support/EasyMacOS/Signing/identity.sha1').read_text().strip()
    tools = ROOT / '.build/sparkle-tools/2.10.1/bin'
    if not (tools / 'sign_update').exists():
        raise SystemExit('请先运行 ./scripts/setup-update-signing.sh。')
    binary_dir = pathlib.Path(run('swift', 'build', '--build-system', 'native', '-c', 'release', '--arch', 'arm64',
                                 '--show-bin-path', capture_output=True, text=True).stdout.strip())
    # 使用持久本地目录保留失败证据，目录名随机生成，且不在版本控制范围内。
    output = pathlib.Path(tempfile.mkdtemp(prefix='easymacos-update-smoke-'))
    print(f'隔离验证目录：{output}', flush=True)
    harness = output / 'UpdateSmoke'
    run('swiftc', '-swift-version', '6', '-parse-as-library', '-O', '-F', binary_dir, '-framework', 'Sparkle',
        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        ROOT / 'scripts/update-smoke.swift', ROOT / 'Sources/PasteMan/UpdateUserDriver.swift',
        ROOT / 'Sources/PasteMan/UpdateController.swift', ROOT / 'Sources/PasteMan/AppVersion.swift', '-o', harness)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(output)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f'http://127.0.0.1:{server.server_port}'
    summary = {}
    try:
        for scenario in ['upgrade', 'cancel-install', 'same-version', 'older-version', 'damaged-archive', 'invalid-signature', 'malformed-feed', 'missing-feed']:
            case = output / scenario
            case.mkdir()
            identifier = 'app.pasteman.UpdateSmoke.' + uuid.uuid4().hex
            result_path = case / 'result.json'
            host = case / 'installed/EasyMacOS.app'
            candidate = case / 'download/EasyMacOS.app'
            result_target = str(result_path)

            def prepare(destination, build, version):
                run('ditto', source, destination)
                shutil.copy2(harness, destination / 'Contents/MacOS/EasyMacOS')
                info = read_info(destination)
                info.update(CFBundleIdentifier=identifier, CFBundleVersion=build, CFBundleShortVersionString=version,
                            SUFeedURL=f'{base_url}/{scenario}/appcast.xml',
                            NSAppTransportSecurity={'NSAllowsArbitraryLoads': True},
                            UpdateSmokeCancelInstall=scenario == 'cancel-install',
                            UpdateSmokeTargetBuild='32', UpdateSmokeResult=result_target)
                write_info(destination, info)
                extension = destination / 'Contents/PlugIns/FinderExtension.appex'
                ext_info = read_info(extension)
                ext_info.update(CFBundleIdentifier=identifier + '.FinderExtension', CFBundleVersion=build,
                                CFBundleShortVersionString=version)
                write_info(extension, ext_info)
                run('codesign', '--force', '--timestamp=none', '--sign', identity,
                    '--entitlements', ROOT / 'Resources/FinderExtension.entitlements', extension, capture_output=True)
                run('codesign', '--force', '--timestamp=none', '--sign', identity, destination, capture_output=True)

            prepare(host, '31', '1.0.30')
            target_build = '31' if scenario == 'same-version' else '30' if scenario == 'older-version' else '32'
            target_version = '1.0.30' if scenario == 'same-version' else '1.0.29' if scenario == 'older-version' else '1.0.31'
            prepare(candidate, target_build, target_version)
            archive = case / 'update.zip'
            run('ditto', '-c', '-k', '--keepParent', candidate, archive)
            signature = run(tools / 'sign_update', '--account', 'EasyMacOS-Update', '-p', archive,
                            capture_output=True, text=True).stdout.strip()
            run(tools / 'sign_update', '--account', 'EasyMacOS-Update', '--verify', archive, signature, capture_output=True)
            if scenario == 'damaged-archive':
                with archive.open('r+b') as target:
                    target.seek(100)
                    target.write(b'CORRUPTED')
            if scenario == 'invalid-signature':
                signature = base64.b64encode(bytes(64)).decode()
            rss = ET.Element('rss', {'version': '2.0', 'xmlns:sparkle': SPARKLE})
            channel = ET.SubElement(rss, 'channel')
            ET.SubElement(channel, 'title').text = '隔离更新验证'
            item = ET.SubElement(channel, 'item')
            ET.SubElement(item, 'title').text = target_version
            ET.SubElement(item, 'sparkle:version').text = target_build
            ET.SubElement(item, 'sparkle:shortVersionString').text = target_version
            ET.SubElement(item, 'sparkle:minimumSystemVersion').text = '15.0'
            ET.SubElement(item, 'description', {'sparkle:format': 'plain-text'}).text = '隔离副本更新验证，不读取真实用户数据。'
            ET.SubElement(item, 'enclosure', {
                'url': f'{base_url}/{scenario}/update.zip', 'length': str(archive.stat().st_size),
                'type': 'application/octet-stream', 'sparkle:edSignature': signature,
            })
            if scenario == 'malformed-feed':
                (case / 'appcast.xml').write_text('这不是有效的更新清单')
            elif scenario != 'missing-feed':
                ET.ElementTree(rss).write(case / 'appcast.xml', encoding='utf-8', xml_declaration=True)
            # 合成历史文件与偏好标记独立于应用包，升级后必须保持不变。
            history = case / 'synthetic-history.txt'
            history.write_text('仅用于升级验证的合成历史与收藏')
            history_hash = hashlib.sha256(history.read_bytes()).hexdigest()
            original = hashlib.sha256((host / 'Contents/Info.plist').read_bytes()).hexdigest()
            with (case / 'application.log').open('wb') as log:
                process = subprocess.Popen([str(host / 'Contents/MacOS/EasyMacOS')], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 65
                    while not result_path.exists() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    if not result_path.exists():
                        raise AssertionError(f'{scenario} 未生成结果，请检查 {case}')
                    result = json.loads(result_path.read_text())
                    assert result['preferencesPreserved'], result
                    assert hashlib.sha256(history.read_bytes()).hexdigest() == history_hash
                    if scenario == 'upgrade':
                        assert result['outcome'] == 'installed' and result['build'] == '32', result
                        assert read_info(host)['CFBundleVersion'] == '32'
                        assert read_info(host / 'Contents/PlugIns/FinderExtension.appex')['CFBundleVersion'] == '32'
                    else:
                        assert result['outcome'] == 'finished' and result['build'] == '31', result
                        if scenario != 'cancel-install':
                            assert result['errorCode'] != 0, result
                        assert hashlib.sha256((host / 'Contents/Info.plist').read_bytes()).hexdigest() == original
                    run('codesign', '--verify', '--deep', '--strict', host, capture_output=True)
                    summary[scenario] = result
                    print(f'通过：{scenario}', flush=True)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
                    # 只清理本轮随机创建的验证应用偏好，不操作正式应用偏好。
                    subprocess.run(['defaults', 'delete', identifier], capture_output=True)
        (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        print(f'全部隔离升级验证通过：{output / "summary.json"}', flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
