//! Benchmark for the Rust `json-escape-simd` crate.
//!
//! The dataset generation, the escape loop, the calibration/timing loop and the
//! report format are byte-for-byte identical to `bench/zig/main.zig`. Do not
//! change one side without changing the other: the printed checksums must match
//! between the two implementations.

use std::hint::black_box;
use std::time::{Duration, Instant};

use json_escape_simd::escape_into;

const SEED_BASE: u64 = 0x243F_6A88_85A3_08D3;
const MIN_SAMPLE: Duration = Duration::from_millis(250);
const SAMPLES: u64 = 7;
const MAX_LEN: usize = 1024;
const DST_CAPACITY: usize = MAX_LEN * 6 + 64;
const PRINTABLE: u64 = 95;

const ESCAPABLE: [u8; 8] = [b'"', b'\\', b'\n', b'\t', b'\r', 0x08, 0x0C, 0x01];

struct Bucket {
    name: &'static str,
    count: usize,
    min_len: u64,
    max_len: u64,
}

const BUCKETS: [Bucket; 3] = [
    Bucket {
        name: "short",
        count: 4096,
        min_len: 2,
        max_len: 32,
    },
    Bucket {
        name: "mid",
        count: 2048,
        min_len: 33,
        max_len: 128,
    },
    Bucket {
        name: "large",
        count: 512,
        min_len: 129,
        max_len: 1024,
    },
];

/// xorshift64*, identical to the Zig `Rng`.
struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng {
            state: if seed == 0 { 0x9E37_79B9_7F4A_7C15 } else { seed },
        }
    }

    fn next(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn seed_for(bucket: u64, workload: u64) -> u64 {
    SEED_BASE ^ bucket.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ workload.wrapping_mul(0xC2B2_AE3D_27D4_EB4F)
}

fn gen_content(rng: &mut Rng, len: usize, needs_escape: bool) -> Vec<u8> {
    let mut buf = vec![0u8; len];
    for b in buf.iter_mut() {
        let r = rng.next();
        let escaped = needs_escape && r % 8 == 0;
        let payload = ((r >> 8) % ESCAPABLE.len() as u64) as usize;
        let plain = (r % PRINTABLE) as u8;
        *b = if escaped { ESCAPABLE[payload] } else { 0x20 + plain };
    }
    if needs_escape {
        let idx = rng.below(len as u64) as usize;
        let payload = rng.below(ESCAPABLE.len() as u64);
        buf[idx] = ESCAPABLE[payload as usize];
    }
    buf
}

fn gen_lengths(rng: &mut Rng, bucket: &Bucket) -> Vec<usize> {
    let mut lengths = Vec::with_capacity(bucket.count);
    for _ in 0..bucket.count {
        let span = bucket.max_len - bucket.min_len + 1;
        lengths.push((bucket.min_len + rng.below(span)) as usize);
    }
    lengths
}

struct Dataset {
    strings: Vec<String>,
    total_bytes: usize,
}

fn build_dataset(lengths: &[usize], rng: &mut Rng, escape_every: bool) -> Dataset {
    let mut strings = Vec::with_capacity(lengths.len());
    let mut total_bytes = 0usize;
    for &len in lengths {
        let needs_escape = if escape_every { true } else { rng.below(100) < 5 };
        strings.push(String::from_utf8(gen_content(rng, len, needs_escape)).unwrap());
        total_bytes += len;
    }
    Dataset {
        strings,
        total_bytes,
    }
}

fn one_pass(strings: &[String], dst: &mut Vec<u8>) -> usize {
    let mut acc = 0usize;
    for s in strings {
        dst.clear();
        escape_into(s.as_str(), dst);
        acc = acc.wrapping_add(dst.len());
    }
    acc
}

fn checksum(strings: &[String], dst: &mut Vec<u8>) -> u64 {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for s in strings {
        dst.clear();
        escape_into(s.as_str(), dst);
        for &b in dst.iter() {
            h ^= b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01B3);
        }
    }
    h
}

fn measure(strings: &[String], dst: &mut Vec<u8>) -> u64 {
    black_box(one_pass(strings, dst));

    let mut reps: u64 = 1;
    let mut elapsed;
    loop {
        let start = Instant::now();
        for _ in 0..reps {
            black_box(one_pass(strings, dst));
        }
        elapsed = start.elapsed();
        if elapsed >= MIN_SAMPLE {
            break;
        }
        reps *= 2;
    }

    let mut best: u64 = elapsed.as_nanos() as u64 / reps;
    for _ in 1..SAMPLES {
        let start = Instant::now();
        for _ in 0..reps {
            black_box(one_pass(strings, dst));
        }
        let ns = start.elapsed().as_nanos() as u64 / reps;
        if ns < best {
            best = ns;
        }
    }
    best
}

fn report(name: &str, dataset: &Dataset, dst: &mut Vec<u8>) {
    let chk = checksum(&dataset.strings, dst);
    let best_ns = measure(&dataset.strings, dst);
    let ps_per_byte = best_ns * 1000 / dataset.total_bytes as u64;
    let mib_per_s = dataset.total_bytes as f64 * 1_000_000_000.0
        / (best_ns as f64 * 1048576.0);
    println!(
        "{:<16} {:>7} {:>10} {:>12} {:>8} {:>10.2} {:>18x}",
        name,
        dataset.strings.len(),
        dataset.total_bytes,
        best_ns,
        ps_per_byte,
        mib_per_s,
        chk
    );
}

fn main() {
    let mut dst = Vec::with_capacity(DST_CAPACITY);

    println!("json_escape benchmark");
    println!(
        "{:<16} {:>7} {:>10} {:>12} {:>8} {:>10} {:>18}",
        "name", "strings", "bytes", "ns/pass", "ps/byte", "MiB/s", "checksum"
    );

    for (bucket_index, bucket) in BUCKETS.iter().enumerate() {
        let mut lengths_rng = Rng::new(seed_for(bucket_index as u64, 0));
        let lengths = gen_lengths(&mut lengths_rng, bucket);

        for (workload, label) in ["every", "realistic"].iter().enumerate() {
            let mut rng = Rng::new(seed_for(bucket_index as u64, workload as u64 + 1));
            let dataset = build_dataset(&lengths, &mut rng, workload == 0);
            let name = format!("{}/{}", bucket.name, label);
            report(&name, &dataset, &mut dst);
        }
    }
}
