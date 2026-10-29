//! Data lives outside the directory the program was unpacked into.
//!
//! A new release is a new folder. Keeping `syncnotes.db` in that folder makes
//! the next version start empty and generate a new seal key. The default is a
//! stable directory; an old database sitting next to the binary is copied once.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataLayout {
    pub db: PathBuf,
    pub files: PathBuf,
    /// Legacy directory the database was copied out of. The originals stay.
    pub migrated_from: Option<PathBuf>,
    /// No database yet. The caller should say where an older copy might be.
    pub fresh: bool,
}

#[derive(Debug, Clone)]
pub struct DataDirEnv {
    pub override_dir: Option<PathBuf>,
    pub is_windows: bool,
    pub is_root: bool,
    pub home: Option<PathBuf>,
    pub xdg_data_home: Option<PathBuf>,
    pub program_data: Option<PathBuf>,
    pub local_app_data: Option<PathBuf>,
}

impl DataDirEnv {
    pub fn from_process() -> Self {
        Self {
            override_dir: std::env::var_os("SYNCNOTES_DATA").map(PathBuf::from),
            is_windows: cfg!(windows),
            is_root: is_root(),
            home: std::env::var_os("HOME").map(PathBuf::from),
            xdg_data_home: std::env::var_os("XDG_DATA_HOME").map(PathBuf::from),
            program_data: std::env::var_os("ProgramData").map(PathBuf::from),
            local_app_data: std::env::var_os("LOCALAPPDATA").map(PathBuf::from),
        }
    }
}

/// Stable directory, not the folder of this version's binary.
pub fn default_data_dir(env: &DataDirEnv) -> PathBuf {
    if let Some(p) = &env.override_dir {
        if !p.as_os_str().is_empty() {
            return p.clone();
        }
    }
    if env.is_windows {
        if let Some(p) = &env.program_data {
            return p.join("SyncNotes");
        }
        if let Some(p) = &env.local_app_data {
            return p.join("SyncNotes");
        }
    } else if env.is_root {
        return PathBuf::from("/var/lib/syncnotes");
    } else if let Some(xdg) = &env.xdg_data_home {
        if !xdg.as_os_str().is_empty() {
            return xdg.join("syncnotes");
        }
    } else if let Some(home) = &env.home {
        if !home.as_os_str().is_empty() {
            return home.join(".local").join("share").join("syncnotes");
        }
    }
    PathBuf::from("syncnotes-data")
}

/// Create the preferred directory, or the next one that is writable.
pub fn pick_data_dir(env: &DataDirEnv) -> PathBuf {
    let primary = default_data_dir(env);
    if fs::create_dir_all(&primary).is_ok() {
        return primary;
    }
    let mut alts = Vec::new();
    if let Some(home) = &env.home {
        alts.push(home.join(".local").join("share").join("syncnotes"));
    }
    if let Some(local) = &env.local_app_data {
        alts.push(local.join("SyncNotes"));
    }
    alts.push(std::env::temp_dir().join("syncnotes-data"));
    for alt in alts {
        if fs::create_dir_all(&alt).is_ok() {
            return alt;
        }
    }
    primary
}

pub struct LayoutInput<'a> {
    pub explicit_db: Option<&'a Path>,
    pub explicit_files: Option<&'a Path>,
    pub data_dir: &'a Path,
    /// Old locations, usually the current directory and the binary's directory.
    pub legacy_dirs: &'a [PathBuf],
}

pub fn resolve_layout(input: LayoutInput<'_>) -> io::Result<DataLayout> {
    if let Some(db) = nonempty(input.explicit_db) {
        let files = match nonempty(input.explicit_files) {
            Some(p) => p.to_path_buf(),
            None => parent_or_dot(db).join("syncnotes-files"),
        };
        if let Some(parent) = db.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)?;
            }
        }
        fs::create_dir_all(&files)?;
        return Ok(DataLayout { db: db.to_path_buf(), files, migrated_from: None, fresh: false });
    }

    fs::create_dir_all(input.data_dir)?;
    let db = input.data_dir.join("syncnotes.db");
    let files = match nonempty(input.explicit_files) {
        Some(p) => p.to_path_buf(),
        None => input.data_dir.join("syncnotes-files"),
    };
    fs::create_dir_all(&files)?;
    let existed = db.exists();

    if !existed {
        for legacy in input.legacy_dirs {
            if same_dir(legacy, input.data_dir) {
                continue;
            }
            let old_db = legacy.join("syncnotes.db");
            let old_files = legacy.join("syncnotes-files");
            if !old_db.exists() && !old_files.is_dir() {
                continue;
            }
            if old_db.exists() {
                fs::copy(&old_db, &db)?;
                for suffix in ["-wal", "-shm", ".seal"] {
                    let src = legacy.join(format!("syncnotes.db{suffix}"));
                    if src.exists() {
                        fs::copy(&src, input.data_dir.join(format!("syncnotes.db{suffix}")))?;
                    }
                }
            }
            if old_files.is_dir() {
                copy_tree(&old_files, &files)?;
            }
            return Ok(DataLayout {
                db,
                files,
                migrated_from: Some(legacy.clone()),
                fresh: false,
            });
        }
    }

    Ok(DataLayout { db, files, migrated_from: None, fresh: !existed })
}

fn nonempty(p: Option<&Path>) -> Option<&Path> {
    p.filter(|p| !p.as_os_str().is_empty())
}

fn parent_or_dot(p: &Path) -> &Path {
    p.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."))
}

fn same_dir(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

fn copy_tree(src: &Path, dst: &Path) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for ent in fs::read_dir(src)? {
        let ent = ent?;
        let to = dst.join(ent.file_name());
        if ent.file_type()?.is_dir() {
            copy_tree(&ent.path(), &to)?;
        } else if !to.exists() {
            fs::copy(ent.path(), &to)?;
        }
    }
    Ok(())
}

fn is_root() -> bool {
    #[cfg(unix)]
    {
        if let Ok(text) = fs::read_to_string("/proc/self/status") {
            for line in text.lines() {
                if let Some(rest) = line.strip_prefix("Uid:") {
                    return rest.split_whitespace().next() == Some("0");
                }
            }
        }
        std::env::var_os("USER").as_deref() == Some(std::ffi::OsStr::new("root"))
    }
    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("syncnotes-paths-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn default_dir_is_outside_the_program_folder() {
        let user = DataDirEnv {
            override_dir: None,
            is_windows: false,
            is_root: false,
            home: Some(PathBuf::from("/home/bill")),
            xdg_data_home: None,
            program_data: None,
            local_app_data: None,
        };
        assert_eq!(
            default_data_dir(&user),
            PathBuf::from("/home/bill/.local/share/syncnotes")
        );
        let root = DataDirEnv { is_root: true, home: Some(PathBuf::from("/root")), ..user.clone() };
        assert_eq!(default_data_dir(&root), PathBuf::from("/var/lib/syncnotes"));
        let over = DataDirEnv {
            override_dir: Some(PathBuf::from("/data/syncnotes")),
            ..user.clone()
        };
        assert_eq!(default_data_dir(&over), PathBuf::from("/data/syncnotes"));
        let win = DataDirEnv {
            is_windows: true,
            program_data: Some(PathBuf::from(r"C:\ProgramData")),
            ..user
        };
        assert_eq!(
            default_data_dir(&win),
            PathBuf::from(r"C:\ProgramData").join("SyncNotes")
        );
    }

    #[test]
    fn legacy_database_is_copied_and_left_in_place() {
        let root = scratch("copy");
        let version = root.join("syncnotes-server-v0.6.8");
        let data = root.join("data");
        fs::create_dir_all(&version).unwrap();
        fs::write(version.join("syncnotes.db"), b"db").unwrap();
        fs::write(version.join("syncnotes.db.seal"), b"seal").unwrap();
        fs::create_dir_all(version.join("syncnotes-files")).unwrap();
        fs::write(version.join("syncnotes-files").join("a.bin"), b"file").unwrap();

        let layout = resolve_layout(LayoutInput {
            explicit_db: None,
            explicit_files: None,
            data_dir: &data,
            legacy_dirs: &[version.clone()],
        })
        .unwrap();

        assert_eq!(layout.db, data.join("syncnotes.db"));
        assert_eq!(fs::read(layout.db).unwrap(), b"db");
        assert_eq!(fs::read(data.join("syncnotes.db.seal")).unwrap(), b"seal");
        assert_eq!(fs::read(layout.files.join("a.bin")).unwrap(), b"file");
        assert_eq!(fs::read(version.join("syncnotes.db")).unwrap(), b"db");
        assert_eq!(layout.migrated_from.as_deref(), Some(version.as_path()));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn existing_data_dir_is_not_overwritten() {
        let root = scratch("keep");
        let version = root.join("old");
        let data = root.join("data");
        fs::create_dir_all(&version).unwrap();
        fs::create_dir_all(&data).unwrap();
        fs::write(version.join("syncnotes.db"), b"old").unwrap();
        fs::write(data.join("syncnotes.db"), b"new").unwrap();
        let layout = resolve_layout(LayoutInput {
            explicit_db: None,
            explicit_files: None,
            data_dir: &data,
            legacy_dirs: &[version],
        })
        .unwrap();
        assert_eq!(fs::read(layout.db).unwrap(), b"new");
        assert!(layout.migrated_from.is_none());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn explicit_db_does_not_migrate() {
        let root = scratch("explicit");
        let version = root.join("old");
        let chosen = root.join("chosen");
        fs::create_dir_all(&version).unwrap();
        fs::write(version.join("syncnotes.db"), b"old").unwrap();
        let db = chosen.join("mine.db");
        let layout = resolve_layout(LayoutInput {
            explicit_db: Some(&db),
            explicit_files: None,
            data_dir: &root.join("data"),
            legacy_dirs: &[version.clone()],
        })
        .unwrap();
        assert_eq!(layout.db, db);
        assert!(!root.join("data").join("syncnotes.db").exists());
        assert!(version.join("syncnotes.db").exists());
        assert!(layout.migrated_from.is_none());
        let _ = fs::remove_dir_all(&root);
    }
}
