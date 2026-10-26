use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket,
};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    fs::{self, OpenOptions},
    io::Write,
    net::{Ipv6Addr, SocketAddrV6},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    time::{sleep, timeout},
};

const SESSION_SECONDS: u64 = 300;

struct State {
    snapshot: Value,
    cancel: Option<Arc<AtomicBool>>,
    running: bool,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(State {
        snapshot: json!({"phase":"idle", "message":"Ready to test on-device wireless pairing."}),
        cancel: None,
        running: false,
    }))
}

fn update(phase: &str, message: impl Into<String>, pin: Option<String>) {
    let mut s = state().lock().unwrap();
    s.snapshot["phase"] = phase.into();
    s.snapshot["message"] = message.into().into();
    s.snapshot["pin"] = pin.map(Value::String).unwrap_or(Value::Null);
}

fn finish(phase: &str, message: impl Into<String>) {
    let mut s = state().lock().unwrap();
    s.snapshot["phase"] = phase.into();
    s.snapshot["message"] = message.into().into();
    s.snapshot["pin"] = Value::Null;
    s.running = false;
    s.cancel = None;
}

fn private_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("pending");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    file.write_all(data)?;
    file.sync_all()?;
    fs::rename(temporary, path)
}

fn start(directory: PathBuf) -> Result<(), String> {
    let mut s = state().lock().unwrap();
    if s.running {
        return Err("An operation is already running.".into());
    }
    fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
        .map_err(|e| e.to_string())?;

    let socket = socket2::Socket::new(
        socket2::Domain::IPV6,
        socket2::Type::STREAM,
        Some(socket2::Protocol::TCP),
    )
    .map_err(|e| e.to_string())?;
    socket.set_only_v6(false).map_err(|e| e.to_string())?;
    socket.set_nonblocking(true).map_err(|e| e.to_string())?;
    socket
        .bind(&SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0).into())
        .map_err(|e| e.to_string())?;
    socket.listen(4).map_err(|e| e.to_string())?;
    let listener: std::net::TcpListener = socket.into();
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();

    // A fresh host identity ensures this experiment does not reuse computer trust.
    let host_label = format!("PhonePair-{}", uuid::Uuid::new_v4());
    let file = RpPairingFile::generate(&host_label);
    let info = PairableHostInfo::generate("PhonePair on this iPhone", "Mac17,7");
    let txt: serde_json::Map<String, Value> = info
        .mdns_txt_records(&file.identifier)
        .into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    let cancel = Arc::new(AtomicBool::new(false));
    s.snapshot = json!({
        "phase":"listening", "message":"Listener ready. Waiting for Bonjour publication.",
        "port":port, "identifier":file.identifier, "txt":txt,
        "service_type":"_remotepairing-pairable-host._tcp.", "pin":null,
    });
    s.running = true;
    s.cancel = Some(cancel.clone());
    drop(s);

    let thread = std::thread::Builder::new().name("PhonePair".into()).spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(r) => r,
            Err(e) => { finish("error", format!("Runtime could not start: {e}")); return; }
        };
        runtime.block_on(async move {
            let operation = accept_pairing(listener, file, info, directory);
            tokio::select! {
                result = timeout(Duration::from_secs(SESSION_SECONDS), operation) => {
                    match result {
                        Ok(Ok(())) => finish("paired", "Pairing exchange completed. Connect LocalDevVPN and tap Verify before exporting."),
                        Ok(Err(e)) => finish("error", e),
                        Err(_) => finish("error", "Five-minute pairing session expired. No new pairing file was exported."),
                    }
                }
                _ = cancelled(cancel) => finish("stopped", "Pairing stopped. No incomplete pairing file was exported."),
            }
        });
    });
    if let Err(e) = thread {
        finish("error", format!("Worker could not start: {e}"));
        return Err(e.to_string());
    }
    Ok(())
}

async fn cancelled(cancel: Arc<AtomicBool>) {
    while !cancel.load(Ordering::Relaxed) {
        sleep(Duration::from_millis(100)).await;
    }
}

async fn accept_pairing(
    listener: std::net::TcpListener,
    mut file: RpPairingFile,
    info: PairableHostInfo,
    directory: PathBuf,
) -> Result<(), String> {
    let listener = TcpListener::from_std(listener).map_err(|e| e.to_string())?;
    let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
    update(
        "connected",
        "iOS connected. Waiting for its pairing handshake.",
        None,
    );
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info.clone());
    let peer = host.accept(&mut file, |pin| async move {
        update("pin", "Enter this code in the iOS pairing prompt. A local notification also shows the code.", Some(pin));
    }).await.map_err(|e| format!("Pairing exchange failed: {e}"))?;

    if file.alt_irk().map(|x| x.len()) != Some(16) || peer.remotepairing_udid.is_empty() {
        return Err(
            "The peer did not supply a complete remote pairing identity. Nothing was exported."
                .into(),
        );
    }
    private_write(
        &directory.join("host-identity.json"),
        &serde_json::to_vec(&json!({
            "identifier":file.identifier, "host_alt_irk":info.alt_irk,
            "peer_udid":peer.remotepairing_udid,
        }))
        .map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    private_write(&directory.join("pairingFile.plist"), &file.to_bytes())
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn verify(directory: PathBuf) -> Result<(), String> {
    let mut s = state().lock().unwrap();
    if s.running {
        return Err("Stop the current operation first.".into());
    }
    let bytes = fs::read(directory.join("pairingFile.plist"))
        .map_err(|_| "No completed pairing file exists yet.".to_string())?;
    let file = RpPairingFile::from_bytes(&bytes).map_err(|e| e.to_string())?;
    let cancel = Arc::new(AtomicBool::new(false));
    s.running = true;
    s.cancel = Some(cancel.clone());
    s.snapshot["phase"] = "verifying".into();
    s.snapshot["message"] =
        "Checking the saved identity through LocalDevVPN at 10.7.0.1:49152.".into();
    s.snapshot["pin"] = Value::Null;
    drop(s);
    let thread = std::thread::Builder::new().name("PhonePairVerify".into()).spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(r) => r,
            Err(e) => { finish("error", e.to_string()); return; }
        };
        runtime.block_on(async move {
            let operation = async move {
                let stream = TcpStream::connect("10.7.0.1:49152").await.map_err(|e| e.to_string())?;
                let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "PhonePair");
                client.attempt_pair_verify().await.map_err(|e| e.to_string())?;
                let mut file = file;
                client.validate_pairing(&mut file).await.map_err(|e| e.to_string())?;
                Ok::<(), String>(())
            };
            tokio::select! {
                result = timeout(Duration::from_secs(20), operation) => match result {
                    Ok(Ok(())) => finish("verified", "iOS accepted this pairing identity through LocalDevVPN. Export it and test Enable JIT in StikDebug."),
                    Ok(Err(e)) => finish("error", format!("Verification failed: {e}. Check LocalDevVPN. The completed file is still available.")),
                    Err(_) => finish("error", "Verification timed out. Connect LocalDevVPN and retry. The completed file is still available."),
                },
                _ = cancelled(cancel) => finish("stopped", "Verification stopped."),
            }
        });
    });
    if let Err(e) = thread {
        finish("error", e.to_string());
        return Err(e.to_string());
    }
    Ok(())
}

/// `path` must point to a valid, NUL-terminated UTF-8 string until this call returns.
unsafe fn directory_from_c(path: *const c_char) -> Result<PathBuf, String> {
    if path.is_null() {
        return Err("Missing output directory.".into());
    }
    let text = unsafe { CStr::from_ptr(path) }
        .to_str()
        .map_err(|e| e.to_string())?;
    if text.is_empty() {
        return Err("Missing output directory.".into());
    }
    Ok(PathBuf::from(text))
}

fn report_error(error: String) {
    let mut s = state().lock().unwrap();
    if !s.running {
        s.snapshot["phase"] = "error".into();
        s.snapshot["message"] = error.into();
    }
}

/// # Safety
/// `path` must be a valid NUL-terminated UTF-8 string, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_start(path: *const c_char) -> i32 {
    match unsafe { directory_from_c(path) }.and_then(start) {
        Ok(()) => 1,
        Err(e) => {
            report_error(e);
            0
        }
    }
}

/// # Safety
/// `path` must be a valid NUL-terminated UTF-8 string, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_verify(path: *const c_char) -> i32 {
    match unsafe { directory_from_c(path) }.and_then(verify) {
        Ok(()) => 1,
        Err(e) => {
            report_error(e);
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn pp_stop() {
    if let Some(cancel) = &state().lock().unwrap().cancel {
        cancel.store(true, Ordering::Relaxed);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn pp_snapshot() -> *mut c_char {
    let s = state().lock().unwrap();
    let mut value = s.snapshot.clone();
    value["running"] = s.running.into();
    CString::new(value.to_string()).unwrap().into_raw()
}

/// # Safety
/// Pass only a non-freed pointer returned by `pp_snapshot`, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::remote_pairing::RpPairingSocketProvider;
    use std::{io::Write, time::Instant};

    fn wait_finished() {
        let deadline = Instant::now() + Duration::from_secs(5);
        while state().lock().unwrap().running {
            assert!(Instant::now() < deadline, "worker did not finish");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn incomplete_exchange_never_exports_and_can_restart() {
        let directory =
            std::env::temp_dir().join(format!("phonepair-test-{}", uuid::Uuid::new_v4()));
        start(directory.clone()).unwrap();
        let first = state().lock().unwrap().snapshot.clone();
        assert_eq!(first["phase"], "listening");
        assert_eq!(first["txt"]["flags"], "1");
        assert!(first["pin"].is_null());
        assert!(!first.to_string().contains("private_key"));
        assert!(!directory.join("pairingFile.plist").exists());
        assert!(start(directory.clone()).is_err());

        let port = first["port"].as_u64().unwrap();
        let mut stream = std::net::TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
        stream.write_all(b"notpairing").unwrap();
        drop(stream);
        wait_finished();
        assert_eq!(state().lock().unwrap().snapshot["phase"], "error");
        assert!(!directory.join("pairingFile.plist").exists());

        start(directory.clone()).unwrap();
        let second = state().lock().unwrap().snapshot.clone();
        assert_ne!(first["identifier"], second["identifier"]);
        pp_stop();
        wait_finished();
        assert_eq!(state().lock().unwrap().snapshot["phase"], "stopped");
        assert!(verify(directory.clone()).is_err());
        assert!(!directory.join("pairingFile.plist").exists());

        // Exercise the actual SRP responder with a peer that supplies a wrong PIN.
        start(directory.clone()).unwrap();
        let port = state().lock().unwrap().snapshot["port"].as_u64().unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            timeout(Duration::from_secs(5), async {
                let stream = TcpStream::connect(format!("127.0.0.1:{port}"))
                    .await
                    .unwrap();
                let mut socket = RpPairingSocket::new(stream);
                socket
                    .send_plain(
                        json!({"request":{"_0":{"handshake":{"_0":{
                            "hostOptions":{"attemptPairVerify":false}, "wireProtocolVersion":26
                        }}}}}),
                        0,
                    )
                    .await
                    .unwrap();
                let response = socket.recv_plain().await.unwrap();
                assert!(response.as_dictionary().unwrap().contains_key("response"));
                let mut client = RemotePairingClient::new(socket, "Test peer");
                let mut file = RpPairingFile::generate("Test peer");
                let result = client
                    .pair(&mut file, || async {
                        let pin = state().lock().unwrap().snapshot["pin"]
                            .as_str()
                            .unwrap()
                            .to_owned();
                        if pin == "000000" {
                            "111111".to_owned()
                        } else {
                            "000000".to_owned()
                        }
                    })
                    .await;
                assert!(result.is_err(), "wrong PIN must be rejected");
            })
            .await
            .expect("wrong PIN exchange hung");
        });
        wait_finished();
        assert_eq!(state().lock().unwrap().snapshot["phase"], "error");
        assert!(!directory.join("pairingFile.plist").exists());

        private_write(
            &directory.join("pairingFile.plist"),
            b"previous completed record",
        )
        .unwrap();
        assert_eq!(
            fs::metadata(directory.join("pairingFile.plist"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        start(directory.clone()).unwrap();
        pp_stop();
        wait_finished();
        assert_eq!(
            fs::read(directory.join("pairingFile.plist")).unwrap(),
            b"previous completed record"
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
