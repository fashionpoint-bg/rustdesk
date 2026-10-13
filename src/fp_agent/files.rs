use std::{
    path::Path,
    time::{Duration, Instant},
};

use hbb_common::{bail, rendezvous_proto::ConnType, ResultType};
use base::{
    fs::{self, DataSource, JobType, TransferJob},
    message_proto::*,
};

use super::session::{connect_and_login, Session};

fn read_dir_msg(path: &str, include_hidden: bool) -> Message {
    let mut action = FileAction::new();
    action.set_read_dir(ReadDir {
        path: path.to_owned(),
        include_hidden,
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_file_action(action);
    msg
}

/// One entry in a remote directory listing.
pub struct Entry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: u64,
}

/// List a directory on the peer.
pub async fn list(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    path: &str,
    include_hidden: bool,
) -> ResultType<Vec<Entry>> {
    let mut session = connect_and_login(key, token, id, password, ConnType::FILE_TRANSFER).await?;
    session.send(read_dir_msg(path, include_hidden)).await?;
    // The peer answers listings from its connection manager process; bound the
    // wait so a peer without one fails cleanly instead of hanging the agent.
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let Some(msg) = session.next_message_until(deadline).await? else {
            bail!("no listing of {path} from {id} within 30s (is a user logged in on the peer?)");
        };
        if let Some(message::Union::FileResponse(fr)) = msg.union {
            match fr.union {
                Some(file_response::Union::Dir(fd)) => {
                    return Ok(fd
                        .entries
                        .into_iter()
                        .map(|e| Entry {
                            is_dir: matches!(
                                e.entry_type.enum_value(),
                                Ok(FileType::Dir) | Ok(FileType::DirLink) | Ok(FileType::DirDrive)
                            ),
                            name: e.name,
                            size: e.size,
                            modified: e.modified_time,
                        })
                        .collect());
                }
                Some(file_response::Union::Error(e)) => bail!("list {path} on {id}: {}", e.error),
                _ => {}
            }
        }
    }
}

/// Download one file from the peer to `local_path`. Returns the byte count.
///
/// A single-file transfer carries an empty entry name (base fs: "the destination
/// file path is carried by transfer metadata"), so the write job's data source
/// must be the full destination file path, not its directory.
pub async fn download(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    remote_path: &str,
    local_path: &Path,
) -> ResultType<u64> {
    if local_path.is_dir() {
        bail!("{} is a directory; give the destination file path", local_path.display());
    }
    if let Some(parent) = local_path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }

    let mut session = connect_and_login(key, token, id, password, ConnType::FILE_TRANSFER).await?;
    let job_id = 0;
    let mut job = TransferJob::new_write(
        job_id,
        JobType::Generic,
        remote_path.to_owned(),
        DataSource::FilePath(local_path.to_path_buf()),
        0,
        false,
        true,  // is_remote: the source is the remote peer
        false, // no overwrite detection: always fetch fresh
    );
    session
        .send(fs::new_send(job_id, JobType::Generic, remote_path.to_owned(), 0, false))
        .await?;

    loop {
        let Some(msg) = session.next_message().await? else {
            bail!("download of {remote_path} from {id} stalled");
        };
        let Some(message::Union::FileResponse(fr)) = msg.union else {
            continue;
        };
        match fr.union {
            Some(file_response::Union::Dir(fd)) => {
                if fd.entries.len() != 1 {
                    bail!("{remote_path} on {id} is not a single file ({} entries)", fd.entries.len());
                }
                job.set_files(fd.entries.to_vec())?;
            }
            Some(file_response::Union::Digest(d)) if !d.is_upload => {
                job.set_digest(d.file_size, d.last_modified);
                let req = FileTransferSendConfirmRequest {
                    id: d.id,
                    file_num: d.file_num,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                    ..Default::default()
                };
                job.confirm(&req).await;
                session.send(fs::new_send_confirm(req)).await?;
            }
            Some(file_response::Union::Block(block)) => {
                job.write(block).await?;
            }
            Some(file_response::Union::Done(_)) => {
                job.modify_time();
                break;
            }
            Some(file_response::Union::Error(e)) => {
                bail!("download {remote_path} from {id}: {}", e.error)
            }
            _ => {}
        }
    }

    if let Some(err) = job.job_error() {
        bail!("download {remote_path} from {id}: {err}");
    }
    Ok(std::fs::metadata(local_path)?.len())
}

/// Wait for the peer's Done / Error answer to file job `job_id`. Upload, mkdir
/// and remove are answered by the peer's connection manager, which runs only
/// while a user is logged in there, so the wait is bounded.
async fn await_result(session: &mut Session, id: &str, what: &str, job_id: i32) -> ResultType<()> {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let Some(msg) = session.next_message_until(deadline).await? else {
            bail!("no answer to {what} from {id} within 60s (is a user logged in on the peer?)");
        };
        if let Some(message::Union::FileResponse(fr)) = msg.union {
            match fr.union {
                Some(file_response::Union::Done(d)) if d.id == job_id => return Ok(()),
                Some(file_response::Union::Error(e)) if e.id == job_id => {
                    bail!("{what} on {id}: {}", e.error)
                }
                _ => {}
            }
        }
    }
}

fn file_action_msg(action: FileAction) -> Message {
    let mut msg = Message::new();
    msg.set_file_action(action);
    msg
}

/// Copy one local file to `remote_path` (the full destination file path) on
/// the peer, overwriting it. Returns the byte count. Mirrors the official
/// client's upload: a read job over the local file, `Receive`, then the blocks
/// and `Done`; the peer answers `Done` once the file is written.
pub async fn upload(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    local_path: &Path,
    remote_path: &str,
) -> ResultType<u64> {
    if !local_path.is_file() {
        bail!("{} is not a file", local_path.display());
    }
    let size = std::fs::metadata(local_path)?.len();
    let job_id = 0;
    let job = TransferJob::new_read(
        job_id,
        JobType::Generic,
        remote_path.to_owned(),
        DataSource::FilePath(local_path.to_path_buf()),
        0,
        false,
        false, // is_remote: the source is this machine
        false, // no overwrite detection: always replace the remote file
    )?;
    let files = job.files().clone();
    let total_size = job.total_size();

    let mut session = connect_and_login(key, token, id, password, ConnType::FILE_TRANSFER).await?;
    session
        .send(fs::new_receive(job_id, remote_path.to_owned(), 0, files, total_size))
        .await?;
    // handle_read_jobs sends one block per call, then Done, and drops the job.
    let mut jobs = vec![job];
    while !jobs.is_empty() {
        fs::handle_read_jobs(&mut jobs, &mut session.stream).await?;
    }
    await_result(&mut session, id, &format!("upload to {remote_path}"), job_id).await?;
    Ok(size)
}

/// Create a directory on the peer.
pub async fn mkdir(key: &str, token: &str, id: &str, password: &str, path: &str) -> ResultType<()> {
    let mut session = connect_and_login(key, token, id, password, ConnType::FILE_TRANSFER).await?;
    let job_id = 1;
    let mut action = FileAction::new();
    action.set_create(FileDirCreate {
        id: job_id,
        path: path.to_owned(),
        ..Default::default()
    });
    session.send(file_action_msg(action)).await?;
    await_result(&mut session, id, &format!("mkdir {path}"), job_id).await
}

/// Remove a file, or an empty directory (with empty subdirectories), on the
/// peer. The peer's directory removal deletes empty directories only, as in
/// the official client, which deletes the files first; a directory with files
/// in it is refused there, and the terminal is the tool for that.
pub async fn remove(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    path: &str,
    is_dir: bool,
) -> ResultType<()> {
    let mut session = connect_and_login(key, token, id, password, ConnType::FILE_TRANSFER).await?;
    let job_id = 1;
    let mut action = FileAction::new();
    if is_dir {
        action.set_remove_dir(FileRemoveDir {
            id: job_id,
            path: path.to_owned(),
            recursive: true,
            ..Default::default()
        });
    } else {
        action.set_remove_file(FileRemoveFile {
            id: job_id,
            path: path.to_owned(),
            file_num: 0,
            ..Default::default()
        });
    }
    session.send(file_action_msg(action)).await?;
    await_result(&mut session, id, &format!("remove {path}"), job_id).await
}
