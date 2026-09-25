import os
import posixpath
import shutil
import sys
import tarfile

archive, destination = sys.argv[1:]
root = os.path.abspath(destination)
deferred_links = []

with tarfile.open(archive, "r:*") as tf:
    members = tf.getmembers()
    names = {member.name: member for member in members}
    os.makedirs(root, exist_ok=True)
    for member in members:
        path = os.path.abspath(os.path.join(root, *member.name.split("/")))
        if os.path.commonpath([root, path]) != root:
            raise RuntimeError(f"unsafe archive path: {member.name}")
        if member.isdir():
            os.makedirs(path, exist_ok=True)
        elif member.isfile():
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with tf.extractfile(member) as src, open(path, "wb") as dst:
                shutil.copyfileobj(src, dst)
            if member.mode & 0o111:
                os.chmod(path, 0o755)
        elif member.issym():
            deferred_links.append((member, path))

    for member, path in deferred_links:
        target_name = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
        target = names.get(target_name)
        while target is not None and target.issym():
            target_name = posixpath.normpath(posixpath.join(posixpath.dirname(target.name), target.linkname))
            target = names.get(target_name)
        if target is None or not target.isfile():
            raise RuntimeError(f"symlink target unavailable: {member.name} -> {member.linkname}")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with tf.extractfile(target) as src, open(path, "wb") as dst:
            shutil.copyfileobj(src, dst)
        if target.mode & 0o111:
            os.chmod(path, 0o755)

source_dir = os.path.join(root, members[0].name.split("/")[0])
with open(os.path.join(source_dir, ".extracted-ok"), "w", encoding="ascii") as marker:
    marker.write("verified source extracted; symlinks materialized as file copies\n")
print(f"extracted {len(members)} entries; copied {len(deferred_links)} source symlinks")
