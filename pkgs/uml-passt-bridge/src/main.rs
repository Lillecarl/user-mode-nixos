//! Bridge between UML fd vector transport and passt.
//!
//! Creates two socketpairs, forks passt (connected to fd 4) and UML
//! (connected to fd 3), then bridges Ethernet frames between them.
//! UML side: raw Ethernet frames.
//! Passt side: 4-byte big-endian length prefix + Ethernet frame.
//!
//! Usage: uml-passt-bridge UML_BINARY [UML_ARGS...]

use std::{
    env, io,
    os::fd::{AsRawFd, BorrowedFd},
    os::unix::process::CommandExt,
    process::{self, exit},
    sync::atomic::{AtomicBool, Ordering},
};

use nix::{
    fcntl,
    sys::{
        signal::{self, kill, Signal},
        socket::{self, AddressFamily, SockType, SockFlag},
    },
    unistd::{self, ForkResult},
};

const POLLIN: i16 = 0x001;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const UML_FD: i32 = 3;
const PASST_FD: i32 = 4;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_term(_sig: i32) {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

fn read_exact(fd: i32, buf: &mut [u8]) -> io::Result<()> {
    let mut off = 0;
    while off < buf.len() {
        match unistd::read(fd, &mut buf[off..]) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof")),
            Ok(n) => off += n,
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut passt_ports: Vec<String> = Vec::new();
    let mut vec_arg = "vec0:transport=fd,fd=3,depth=512,gro=1".to_string();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--vec" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("--vec requires an argument");
                    exit(1);
                }
                vec_arg = args[i].clone();
            }
            "--passt-port" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("--passt-port requires an argument");
                    exit(1);
                }
                passt_ports.push(args[i].clone());
            }
            _ => break,
        }
        i += 1;
    }

    if i >= args.len() {
        eprintln!(
            "Usage: {} [--vec VEC_ARG] [--passt-port PORT] UML_BINARY [UML_ARGS...]",
            args[0]
        );
        exit(1);
    }

    let (uml_a, uml_b) = socket::socketpair(
        AddressFamily::Unix,
        SockType::SeqPacket,
        None,
        SockFlag::empty(),
    )
    .expect("socketpair uml");
    let (passt_a, passt_b) = socket::socketpair(
        AddressFamily::Unix,
        SockType::Stream,
        None,
        SockFlag::empty(),
    )
    .expect("socketpair passt");

    // No --one-off: we kill passt ourselves when the bridge exits, and
    // letting it linger keeps the uplink up across a guest's reboot.
    let mut passt_args: Vec<String> =
        vec!["--foreground".into(), "--fd".into(), "4".into()];
    for port in &passt_ports {
        passt_args.push("-t".into());
        passt_args.push(port.clone());
    }

    let passt_pid = match unsafe { unistd::fork() }.expect("fork passt") {
        ForkResult::Child => {
            drop(uml_a);
            drop(uml_b);
            drop(passt_a);
            unistd::dup2(passt_b.as_raw_fd(), PASST_FD).expect("dup2 passt");
            drop(passt_b);
            let passt_argv: Vec<&str> = passt_args.iter().map(|s| s.as_str()).collect();
            let err = process::Command::new("passt").args(&passt_argv).exec();
            eprintln!("exec passt: {}", err);
            exit(1);
        }
        ForkResult::Parent { child } => child,
    };

    let uml_pid = match unsafe { unistd::fork() }.expect("fork uml") {
        ForkResult::Child => {
            drop(passt_a);
            drop(passt_b);
            drop(uml_a);
            unistd::dup2(uml_b.as_raw_fd(), UML_FD).expect("dup2 uml");
            drop(uml_b);
            fcntl::fcntl(UML_FD, fcntl::FcntlArg::F_SETFD(fcntl::FdFlag::empty()))
                .expect("fcntl uml");

            let kernel = &args[i];
            let mut full_args: Vec<String> = args.iter().skip(i + 1).cloned().collect();
            full_args.push(vec_arg.clone());
            let err = process::Command::new(kernel).args(&full_args).exec();
            eprintln!("exec uml {}: {}", kernel, err);
            exit(1);
        }
        ForkResult::Parent { child } => child,
    };

    // Parent: keep both ends alive so socketpairs survive child exits.
    let uml_r = uml_a.as_raw_fd();
    let passt_r = passt_a.as_raw_fd();
    let _uml_b = uml_b;
    let _passt_b = passt_b;

    unsafe {
        signal::signal(Signal::SIGTERM, signal::SigHandler::Handler(handle_term)).ok();
        signal::signal(Signal::SIGINT, signal::SigHandler::Handler(handle_term)).ok();
        signal::signal(Signal::SIGHUP, signal::SigHandler::Handler(handle_term)).ok();
        signal::signal(Signal::SIGPIPE, signal::SigHandler::SigIgn).ok();
        libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
    }

    let mut pfds = [
        libc::pollfd { fd: uml_r, events: POLLIN, revents: 0 },
        libc::pollfd { fd: passt_r, events: POLLIN, revents: 0 },
    ];

    let mut buf = vec![0u8; 65536];
    let mut framed = vec![0u8; 65540];

    loop {
        if SHUTDOWN.load(Ordering::SeqCst) {
            break;
        }

        let ret = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, 1000) };
        if ret < 0 {
            let e = io::Error::last_os_error();
            if e.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            eprintln!("poll error: {}", e);
            break;
        }

        // UML -> passt: read raw frame, prepend 4-byte BE length, forward.
        if pfds[0].revents & (POLLIN | POLLERR | POLLHUP) != 0 {
            if pfds[0].revents & (POLLHUP | POLLERR) != 0 {
                break;
            }
            match unistd::read(uml_r, &mut buf) {
                Ok(n) if n > 0 => {
                    let len_be = (n as u32).to_be_bytes();
                    framed[..4].copy_from_slice(&len_be);
                    framed[4..4 + n].copy_from_slice(&buf[..n]);
                    let bfd = unsafe { BorrowedFd::borrow_raw(passt_r) };
                    match unistd::write(&bfd, &framed[..4 + n]) {
                        Ok(_) => {}
                        Err(e) => {
                            eprintln!("passt write error: {}", e);
                            break;
                        }
                    }
                }
                _ => {
                    eprintln!("uml read eof");
                    break;
                }
            }
        }

        // Passt -> UML: read 4-byte BE length, read payload, forward raw.
        if pfds[1].revents & (POLLIN | POLLERR | POLLHUP) != 0 {
            if pfds[1].revents & (POLLHUP | POLLERR) != 0 {
                break;
            }
            let mut len_be = [0u8; 4];
            if read_exact(passt_r, &mut len_be).is_err() {
                eprintln!("passt read header eof");
                break;
            }
            let len = u32::from_be_bytes(len_be) as usize;
            if len > buf.len() {
                eprintln!("passt frame too large: {}", len);
                break;
            }
            if read_exact(passt_r, &mut buf[..len]).is_err() {
                eprintln!("passt read payload eof");
                break;
            }
            let bfd = unsafe { BorrowedFd::borrow_raw(uml_r) };
            match unistd::write(&bfd, &buf[..len]) {
                Ok(_) => {}
                Err(e) => {
                    eprintln!("uml write error: {}", e);
                    break;
                }
            }
        }
    }

    // Kill children so nothing leaks.
    let _ = kill(passt_pid, Signal::SIGKILL);
    let _ = kill(uml_pid, Signal::SIGKILL);
}
