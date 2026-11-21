"""Frontend-only publisher, called with the common server flock held by release.sh.

Digests live outside the served tree. A pre-CodeDeploy release may be adopted
only by replaying its exact SHA's trusted bundle and comparing the ENTIRE tree.
An unknown legacy current must be adopted this way before switching away from it;
never bless arbitrary on-disk bytes as a rollback baseline.
"""
import hashlib
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
from html.parser import HTMLParser
from pathlib import Path


SHA = re.compile(r'[0-9a-f]{40}')
HOST = 'private-mailhub.com'
ROOT = Path(os.environ.get('MAILHUB_DEPLOY_ROOT', '/var/www/mailhub-frontend'))
RELEASES, ASSETS = ROOT / 'releases', ROOT / 'shared' / 'assets'
STATE, CURRENT = ROOT / '.release-state', ROOT / 'current'
PENDING = STATE / 'pending'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular(path):
    mode = path.lstat()
    require(stat.S_ISREG(mode.st_mode) and mode.st_nlink == 1, f'not a regular single-link file: {path}')
    return path


def directory(path):
    require(stat.S_ISDIR(path.lstat().st_mode), f'not a directory: {path}')
    return path


def digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(block)
    return result.digest()


def file_digest(path):
    with regular(path).open('rb') as stream:
        return digest(stream)


def walk(root):
    for path in sorted(directory(root).iterdir()):
        if stat.S_ISDIR(path.lstat().st_mode):
            yield path, True
            yield from walk(path)
        else:
            yield regular(path), False


def tree_digest(root):
    # Include every file, empty directory, path, type and permission mode; ignore
    # archive timestamps/uid so repacks of the same static tree remain identical.
    result = hashlib.sha256()
    require(stat.S_IMODE(directory(root).stat().st_mode) == 0o755, 'release root must have mode 0755')
    for path, is_dir in walk(root):
        mode = 0o755 if is_dir else 0o644
        require(stat.S_IMODE(path.stat().st_mode) == mode, f'unexpected release permissions: {path}')
        result.update(b'D' if is_dir else b'F')
        result.update(os.fsencode(path.relative_to(root)) + b'\0')
        if not is_dir:
            result.update(file_digest(path))
    return result.hexdigest()


def atomic_text(path, value):
    with tempfile.NamedTemporaryFile(dir=STATE, delete=False) as tmp:
        name = Path(tmp.name)
        try:
            tmp.write(value.encode('ascii'))
            tmp.flush()
            os.fsync(tmp.fileno())
            os.replace(name, path)
        finally:
            if name.exists():
                name.unlink()


def recorded(sha):
    path = STATE / (sha + '.sha256')
    if not os.path.lexists(path):
        return None
    value = regular(path).read_text(encoding='ascii')
    require(re.fullmatch(r'[0-9a-f]{64}\n', value), f'invalid release digest for {sha}')
    return value.rstrip('\n')


def verify_known(sha):
    expected = recorded(sha)
    require(expected, f'no trusted digest for {sha}; replay its exact verified bundle before switching')
    require(tree_digest(RELEASES / sha) == expected, f'release tree no longer matches trusted digest: {sha}')


def extract(stream, dest, wrapped):
    seen = set()
    size = 0
    with tarfile.open(fileobj=stream, mode='r|gz') as tar:
        for entry in tar:
            name = entry.name
            if name.startswith('./'):
                name = name[2:]
            if name in ('', '.') and entry.isdir():
                continue
            parts = name.split('/')
            require(all(part not in ('', '.', '..') and not any(ord(c) < 32 for c in part) for part in parts), 'unsafe archive path')
            if wrapped:
                require(parts[0] == 'dist', 'legacy archive must use dist/ at its root')
                parts = parts[1:]
                if not parts and entry.isdir():
                    continue
            require(parts and (entry.isdir() or entry.isreg()), 'unsupported archive entry')
            target = dest.joinpath(*parts)
            require(target not in seen, f'duplicate archive member: {name}')
            seen.add(target)
            size += entry.size
            require(len(seen) <= 20000 and size <= 512 * 1024 * 1024, 'static archive exceeds release limits')
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(entry) as src, target.open('xb') as out:
                    shutil.copyfileobj(src, out)
    regular(dest / 'index.html')
    directory(dest / 'assets')
    dest.chmod(0o755)


def publish_assets(source):
    # Inspect before writing: a collision (including directory/file shape) never
    # partially publishes a candidate. Keep assets for old tabs and rollbacks.
    for path, is_dir in walk(ASSETS):
        mode = 0o755 if is_dir else 0o644
        if stat.S_IMODE(path.stat().st_mode) != mode:
            path.chmod(mode)
    missing = []
    for path, is_dir in walk(source):
        target = ASSETS / path.relative_to(source)
        if os.path.lexists(target):
            if is_dir:
                directory(target)
            else:
                require(file_digest(target) == file_digest(path), f'asset collision: {target.name}')
        else:
            missing.append((path, target, is_dir))
    for path, target, is_dir in missing:
        if is_dir:
            target.mkdir()
        else:
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.mailhub-asset-', delete=False) as tmp:
                name = Path(tmp.name)
                try:
                    with path.open('rb') as src:
                        shutil.copyfileobj(src, tmp)
                    tmp.flush()
                    os.fchmod(tmp.fileno(), 0o644)
                    # All writers hold the same flock; rename makes only complete
                    # bytes visible and leaves no partial link pair after a crash.
                    require(not os.path.lexists(target), f'asset appeared during publication: {target.name}')
                    os.rename(name, target)
                finally:
                    if name.exists():
                        name.unlink()


def prepare(sha, archive, expected, wrapped):
    release = RELEASES / sha
    with tempfile.TemporaryDirectory(dir=RELEASES, prefix='.staging-') as workspace:
        staged = Path(workspace) / 'site'
        staged.mkdir()
        with regular(archive).open('rb') as stream:
            if expected is not None:
                require(digest(stream).hex() == expected, 'frontend archive checksum mismatch')
                stream.seek(0)
            extract(stream, staged, wrapped)
        tree = tree_digest(staged)
        known = recorded(sha)
        require(known is None or tree == known, f'different bytes for immutable SHA {sha}')
        if os.path.lexists(release):
            require(tree_digest(release) == tree, f'existing release differs from verified bundle: {sha}')
        else:
            require(known is None, f'previously recorded release directory is missing: {sha}')
        publish_assets(staged / 'assets')
        if not os.path.lexists(release):
            staged.rename(release)
        # Only the checksummed CodeDeploy path may establish rollback evidence.
        if known is None and expected is not None:
            atomic_text(STATE / (sha + '.sha256'), tree + '\n')


def current_sha():
    if not os.path.lexists(CURRENT):
        return None
    require(CURRENT.is_symlink(), 'current must be a symbolic link')
    target = ROOT / os.readlink(CURRENT)
    require(target.parent == RELEASES and SHA.fullmatch(target.name), 'current is not a canonical SHA release')
    directory(target)
    return target.name


def switch(sha):
    if sha is None:
        CURRENT.unlink()
        return
    with tempfile.TemporaryDirectory(dir=ROOT, prefix='.switch-') as workspace:
        link = Path(workspace) / 'current'
        link.symlink_to(RELEASES / sha)
        os.replace(link, CURRENT)


class Scripts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()

    def handle_starttag(self, tag, attrs):
        src = dict(attrs).get('src') or ''
        if tag == 'script' and src.startswith('/assets/'):
            require(re.fullmatch(r'/assets/(?:[a-zA-Z0-9_-][a-zA-Z0-9_.-]*/)*[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.m?js', src), 'unsupported local script URL')
            self.paths.add(src)


def probe(sha):
    require(current_sha() == sha, f'expected active SHA {sha}')
    site = RELEASES / sha
    with tempfile.TemporaryDirectory() as workspace:
        body = Path(workspace) / 'response'

        def fetch(url_path, reference):
            status = subprocess.check_output([
                'curl', '--disable', '--noproxy', '*', '--proto', '=https', '--resolve',
                f'{HOST}:443:127.0.0.1', '--connect-timeout', '3', '--max-time', '10',
                '--fail', '--silent', '--show-error', '--header', 'Cache-Control: no-cache',
                '--output', str(body), '--write-out', '%{http_code} %{content_type}', f'https://{HOST}{url_path}',
            ], text=True)
            code, _, content_type = status.partition(' ')
            media = content_type.partition(';')[0].strip().lower()
            accepted = {'text/html'} if url_path == '/' else {'application/javascript', 'text/javascript',
                                                             'application/ecmascript', 'text/ecmascript',
                                                             'application/x-javascript'}
            require(code == '200' and media in accepted and file_digest(body) == file_digest(reference),
                    f'served status, type or bytes do not match release {sha}: {url_path}')

        fetch('/', site / 'index.html')
        parser = Scripts()
        parser.feed(body.read_text(encoding='utf-8'))
        parser.close()
        require(parser.paths, 'served HTML has no local JavaScript entrypoint')
        for path in sorted(parser.paths):
            fetch(path, site / path[1:])
    require(current_sha() == sha, 'active SHA changed during HTTPS proof')


def recover():
    if not os.path.lexists(PENDING):
        return
    transaction = regular(PENDING).read_text(encoding='ascii')
    match = re.fullmatch(r'(-|[0-9a-f]{40}) ([0-9a-f]{40})\n', transaction)
    require(match, 'invalid pending transaction')
    before, candidate = match.groups()
    before = None if before == '-' else before
    active = current_sha()
    require(active in (before, candidate), 'current changed outside pending transaction; refusing rollback')
    if before:
        verify_known(before)
    if active != before:
        switch(before)
    if before:
        probe(before)
        print(f'Restored and verified previous frontend {before}', flush=True)
    else:
        require(current_sha() is None, 'bootstrap correction failed')
        print('Restored bootstrap state: no previous current release', flush=True)
    PENDING.unlink()


def activate(sha):
    verify_known(sha)
    before = current_sha()
    if before == sha:
        probe(sha)  # A repeat does not replace the directory or even its symlink.
        return
    if before:
        verify_known(before)
    atomic_text(PENDING, f'{before or "-"} {sha}\n')
    try:
        switch(sha)
        probe(sha)
        PENDING.unlink()
    except BaseException:
        # Keep journal if restoration/its probe fails. Next hook resumes under lock.
        recover()
        raise


def run(mode, value):
    require(ROOT.is_absolute() and ROOT != Path('/') and '..' not in ROOT.parts,
            'deployment root must be a dedicated absolute path')
    for path in (ROOT, RELEASES, ROOT / 'shared', ASSETS, STATE):
        path.mkdir(exist_ok=True)
        directory(path).chmod(0o700 if path == STATE else 0o755)
    recover()
    if mode in ('--prepare', '--activate'):
        bundle = Path(value)
        revision = regular(bundle / 'revision.txt').read_bytes()
        require(re.fullmatch(rb'[0-9a-f]{40}\n?', revision), 'invalid revision.txt')
        sha = revision.rstrip(b'\n').decode('ascii')
        checksum = regular(bundle / 'frontend.tar.gz.sha256').read_bytes()
        match = re.fullmatch(rb'([0-9a-f]{64}) [ *]frontend\.tar\.gz\n?', checksum)
        require(match, 'expected exactly one GNU checksum for frontend.tar.gz')
        prepare(sha, bundle / 'frontend.tar.gz', match[1].decode('ascii'), False)
        if mode == '--activate':
            activate(sha)
    else:
        # Historical local preparation/first Nginx cutover only; not a CodeDeploy path.
        sha = mode.lower()
        require(SHA.fullmatch(sha), 'invalid release SHA')
        current_sha()
        prepare(sha, Path(value), None, True)
        if current_sha() != sha:
            switch(sha)
    print(f'{mode if mode.startswith("--") else "Published"}: frontend {sha}', flush=True)


if __name__ == '__main__':
    def stop(_signum, _frame):
        raise RuntimeError('deployment interrupted')

    signal.signal(signal.SIGTERM, stop)
    try:
        run(*sys.argv[1:])
    except (ValueError, OSError, RuntimeError, tarfile.TarError, EOFError, subprocess.SubprocessError) as error:
        sys.exit(f'ERROR: {error}')
