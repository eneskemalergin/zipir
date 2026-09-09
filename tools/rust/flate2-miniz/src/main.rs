//! Zebrac adapter for flate2 with the miniz_oxide backend.

use flate2::read::MultiGzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use std::env;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::process;

const NAME: &str = "flate2-miniz";
const VERSION: &str = "1.1.10";

fn main() {
    if let Err(err) = run() {
        eprintln!("{err}");
        process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if args.first().map(String::as_str) == Some("--version") {
        if args.len() != 1 {
            return Err(usage());
        }
        println!("{NAME} {VERSION}");
        return Ok(());
    }
    if args.len() < 3 {
        return Err(usage());
    }
    match args[0].as_str() {
        "compress" => {
            let level = take_level(&mut args)?;
            if args.len() != 3 {
                return Err(usage());
            }
            let mut input = open_in(&args[1])?;
            let output = open_out(&args[2])?;
            let mut encoder = GzEncoder::new(BufWriter::new(output), Compression::new(level));
            io::copy(&mut input, &mut encoder).map_err(|e| e.to_string())?;
            encoder.finish().map_err(|e| e.to_string())?;
        }
        "decompress" => {
            if args.len() != 3 {
                return Err(usage());
            }
            let input = open_in(&args[1])?;
            let mut output = BufWriter::new(open_out(&args[2])?);
            let mut decoder = MultiGzDecoder::new(BufReader::new(input));
            io::copy(&mut decoder, &mut output).map_err(|e| e.to_string())?;
            output.flush().map_err(|e| e.to_string())?;
        }
        _ => return Err(usage()),
    }
    Ok(())
}

fn take_level(args: &mut Vec<String>) -> Result<u32, String> {
    if args.get(1).map(String::as_str) != Some("--level") {
        return Err(usage());
    }
    let text = args.get(2).cloned().ok_or_else(usage)?;
    let level: u32 = text.parse().map_err(|_| usage())?;
    if level > 9 {
        return Err(usage());
    }
    args.remove(1);
    args.remove(1);
    Ok(level)
}

fn open_in(path: &str) -> Result<Box<dyn Read>, String> {
    if path == "-" {
        return Ok(Box::new(io::stdin()));
    }
    File::open(path)
        .map(|f| Box::new(f) as Box<dyn Read>)
        .map_err(|e| e.to_string())
}

fn open_out(path: &str) -> Result<Box<dyn Write>, String> {
    if path == "-" {
        return Ok(Box::new(io::stdout()));
    }
    File::create(path)
        .map(|f| Box::new(f) as Box<dyn Write>)
        .map_err(|e| e.to_string())
}

fn usage() -> String {
    format!(
        "usage: {NAME} --version\n       {NAME} compress --level N IN OUT\n       {NAME} decompress IN OUT"
    )
}
