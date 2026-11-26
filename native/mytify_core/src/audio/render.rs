use super::decoder::Stereo;
use super::eq;
use rtrb::{Consumer, Producer, RingBuffer};
use std::sync::{
    atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
    Arc,
};
pub const BLOCK: usize = 512;
/// Last mono samples sent to the output, read by the level display. Power of two.
pub const SCOPE: usize = 4096;
pub struct AudioBlock {
    pub samples: [Stereo; BLOCK],
    pub len: usize,
    pub track: usize,
    pub start: u64,
    pub epoch: u64,
    pub terminal: bool,
}
impl AudioBlock {
    fn new() -> Box<Self> {
        Box::new(Self {
            samples: [[0.0; 2]; BLOCK],
            len: 0,
            track: 0,
            start: 0,
            epoch: 0,
            terminal: false,
        })
    }
}
pub struct Signals {
    pub epoch: AtomicU64,
    pub paused: AtomicBool,
    pub ready: AtomicBool,
    pub completed: AtomicBool,
    pub active: AtomicUsize,
    pub position: AtomicU64,
    pub gain: AtomicU32,
    pub underrun_frames: AtomicU64,
    pub rendered_frames: AtomicU64,
    pub device_failed: AtomicBool,
    /// Ring of rendered mono samples (f32 bits, before volume) and the count written so far.
    pub scope: Box<[AtomicU32]>,
    pub scope_head: AtomicU64,
    pub eq: eq::Shared,
}
impl Signals {
    pub fn new(volume: f32) -> Self {
        Self {
            epoch: AtomicU64::new(1),
            paused: AtomicBool::new(true),
            ready: AtomicBool::new(false),
            completed: AtomicBool::new(false),
            active: AtomicUsize::new(usize::MAX),
            position: AtomicU64::new(0),
            gain: AtomicU32::new((volume / 100.0).to_bits()),
            underrun_frames: AtomicU64::new(0),
            rendered_frames: AtomicU64::new(0),
            device_failed: AtomicBool::new(false),
            scope: (0..SCOPE).map(|_| AtomicU32::new(0)).collect(),
            scope_head: AtomicU64::new(0),
            eq: eq::Shared::new(&eq::Equalizer::default()),
        }
    }
}
pub struct Feeder {
    pub ready: Producer<Box<AudioBlock>>,
    pub free: Consumer<Box<AudioBlock>>,
    pub spare: Option<Box<AudioBlock>>,
    pub pushed: usize,
}
impl Feeder {
    pub fn take(&mut self) -> Option<Box<AudioBlock>> {
        self.spare.take().or_else(|| self.free.pop().ok())
    }
    pub fn send(&mut self, block: Box<AudioBlock>) {
        if let Err(rtrb::PushError::Full(block)) = self.ready.push(block) {
            self.spare = Some(block);
        } else {
            self.pushed += 1;
        }
    }
}
/// Callback core: no allocation, no locks, no disk/network IO. Blocks return to a preallocated pool.
pub struct Renderer {
    ready: Consumer<Box<AudioBlock>>,
    free: Producer<Box<AudioBlock>>,
    current: Option<Box<AudioBlock>>,
    offset: usize,
    pub signals: Arc<Signals>,
    gain: f32,
    step: f32,
    eq: eq::Filter,
}
pub fn pipe(rate: u32, signals: Arc<Signals>) -> (Feeder, Renderer) {
    let count = ((rate as usize * 3) / BLOCK).clamp(32, 2048);
    let (ready_tx, ready_rx) = RingBuffer::new(count + 1);
    let (mut free_tx, free_rx) = RingBuffer::new(count + 1);
    for _ in 0..count {
        let _ = free_tx.push(AudioBlock::new());
    }
    (
        Feeder {
            ready: ready_tx,
            free: free_rx,
            spare: None,
            pushed: 0,
        },
        Renderer {
            ready: ready_rx,
            free: free_tx,
            current: None,
            offset: 0,
            gain: f32::from_bits(signals.gain.load(Ordering::Relaxed)),
            step: 1.0 / (rate as f32 * 0.005),
            eq: eq::Filter::new(rate),
            signals,
        },
    )
}
impl Renderer {
    fn recycle(&mut self, block: Box<AudioBlock>) {
        // Pool accounting guarantees capacity: free + ready + current + worker = fixed count.
        if let Err(rtrb::PushError::Full(block)) = self.free.push(block) {
            std::mem::forget(block);
            self.signals.device_failed.store(true, Ordering::Release);
        }
    }
    fn purge(&mut self, epoch: u64) {
        if self.current.as_ref().is_some_and(|b| b.epoch != epoch) {
            let old = self.current.take().unwrap();
            self.recycle(old);
            self.offset = 0;
        }
        while self.ready.peek().is_ok_and(|b| b.epoch != epoch) {
            if let Ok(old) = self.ready.pop() {
                self.recycle(old);
            } else {
                break;
            }
        }
    }
    pub fn render(&mut self, output: &mut [f32], channels: usize) {
        output.fill(0.0);
        if channels == 0 {
            return;
        }
        let epoch = self.signals.epoch.load(Ordering::Acquire);
        self.purge(epoch);
        if self.signals.paused.load(Ordering::Acquire)
            || !self.signals.ready.load(Ordering::Acquire)
        {
            return;
        }
        let gain = f32::from_bits(self.signals.gain.load(Ordering::Relaxed));
        self.eq.update(&self.signals.eq);
        let mut last = None;
        let mut rendered = 0;
        let mut head = self.signals.scope_head.load(Ordering::Relaxed);
        for target in output.chunks_exact_mut(channels) {
            loop {
                if self
                    .current
                    .as_ref()
                    .is_some_and(|b| self.offset >= b.len && !b.terminal)
                {
                    let old = self.current.take().unwrap();
                    self.recycle(old);
                    self.offset = 0;
                }
                if self.current.is_none() {
                    self.current = self.ready.pop().ok();
                    self.offset = 0;
                }
                let Some(block) = self.current.as_ref() else {
                    self.signals.underrun_frames.fetch_add(1, Ordering::Relaxed);
                    break;
                };
                if block.epoch != epoch {
                    let old = self.current.take().unwrap();
                    self.recycle(old);
                    continue;
                }
                if block.terminal {
                    self.signals.completed.store(true, Ordering::Release);
                    self.signals.paused.store(true, Ordering::Release);
                    let old = self.current.take().unwrap();
                    self.recycle(old);
                    break;
                }
                let sample = self.eq.process(block.samples[self.offset]);
                self.signals.scope[(head as usize) & (SCOPE - 1)]
                    .store(((sample[0] + sample[1]) * 0.5).to_bits(), Ordering::Relaxed);
                head += 1;
                self.gain += (gain - self.gain).clamp(-self.step, self.step);
                let gain = self.gain;
                if channels == 1 {
                    target[0] = ((sample[0] + sample[1]) * 0.5 * gain).clamp(-1.0, 1.0);
                } else {
                    target[0] = (sample[0] * gain).clamp(-1.0, 1.0);
                    target[1] = (sample[1] * gain).clamp(-1.0, 1.0);
                }
                self.offset += 1;
                last = Some((block.track, block.start + self.offset as u64));
                rendered += 1;
                break;
            }
            if self.signals.paused.load(Ordering::Relaxed) {
                break;
            }
        }
        self.signals.scope_head.store(head, Ordering::Release);
        if let Some((track, position)) = last {
            self.signals.active.store(track, Ordering::Release);
            self.signals.position.store(position, Ordering::Release);
        }
        self.signals
            .rendered_frames
            .fetch_add(rendered, Ordering::Relaxed);
    }
}
