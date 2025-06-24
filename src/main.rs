use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use parking_lot::RwLock;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tracing::{info, warn, error};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub order_id: u64,
    pub price: f64,
    pub size: f64,
    pub timestamp: i64,
}

#[derive(Debug, Default)]
pub struct PriceLevel {
    pub price: f64,
    pub orders: DashMap<u64, Order>,
    pub total_size: AtomicU64,
}

impl PriceLevel {
    fn new(price: f64) -> Self {
        Self {
            price,
            orders: DashMap::new(),
            total_size: AtomicU64::new(0),
        }
    }

    fn add_order(&self, order: Order) {
        let size_bits = order.size.to_bits();
        self.orders.insert(order.order_id, order);
        self.total_size.fetch_add(size_bits, Ordering::Relaxed);
    }

    fn remove_order(&self, order_id: u64) -> Option<Order> {
        if let Some((_, order)) = self.orders.remove(&order_id) {
            let size_bits = order.size.to_bits();
            self.total_size.fetch_sub(size_bits, Ordering::Relaxed);
            Some(order)
        } else {
            None
        }
    }

    fn total_size(&self) -> f64 {
        f64::from_bits(self.total_size.load(Ordering::Relaxed))
    }
}

pub struct Orderbook {
    market_id: u16,
    bids: Arc<RwLock<BTreeMap<u64, Arc<PriceLevel>>>>, // Negative price as key for desc order
    asks: Arc<RwLock<BTreeMap<u64, Arc<PriceLevel>>>>,
    order_locations: DashMap<u64, (bool, u64)>, // order_id -> (is_bid, price_bits)
    sequence: AtomicU64,
    last_update: AtomicU64,
}

impl Orderbook {
    pub fn new(market_id: u16) -> Self {
        Self {
            market_id,
            bids: Arc::new(RwLock::new(BTreeMap::new())),
            asks: Arc::new(RwLock::new(BTreeMap::new())),
            order_locations: DashMap::new(),
            sequence: AtomicU64::new(0),
            last_update: AtomicU64::new(0),
        }
    }

    pub fn add_order(&self, order_id: u64, is_buy: bool, price: f64, size: f64, timestamp: i64) {
        let order = Order {
            order_id,
            price,
            size,
            timestamp,
        };

        let price_bits = price.to_bits();

        if is_buy {
            let mut bids = self.bids.write();
            let level = bids
                .entry(u64::MAX - price_bits) // Negative for descending order
                .or_insert_with(|| Arc::new(PriceLevel::new(price)));
            level.add_order(order);
        } else {
            let mut asks = self.asks.write();
            let level = asks
                .entry(price_bits)
                .or_insert_with(|| Arc::new(PriceLevel::new(price)));
            level.add_order(order);
        }

        self.order_locations.insert(order_id, (is_buy, price_bits));
        self.sequence.fetch_add(1, Ordering::Relaxed);
        self.last_update.store(timestamp as u64, Ordering::Relaxed);
    }

    pub fn cancel_order(&self, order_id: u64) -> bool {
        if let Some((_, (is_buy, price_bits))) = self.order_locations.remove(&order_id) {
            if is_buy {
                let mut bids = self.bids.write();
                let key = u64::MAX - price_bits;
                if let Some(level) = bids.get(&key) {
                    level.remove_order(order_id);
                    if level.orders.is_empty() {
                        bids.remove(&key);
                    }
                }
            } else {
                let mut asks = self.asks.write();
                if let Some(level) = asks.get(&price_bits) {
                    level.remove_order(order_id);
                    if level.orders.is_empty() {
                        asks.remove(&price_bits);
                    }
                }
            }
            self.sequence.fetch_add(1, Ordering::Relaxed);
            true
        } else {
            false
        }
    }

    pub fn get_snapshot(&self, depth: usize) -> OrderbookSnapshot {
        let bids = self.bids.read();
        let asks = self.asks.read();

        let bid_levels: Vec<_> = bids
            .iter()
            .take(depth)
            .map(|(_, level)| Level {
                price: level.price,
                size: level.total_size(),
                orders: level.orders.len(),
            })
            .collect();

        let ask_levels: Vec<_> = asks
            .iter()
            .take(depth)
            .map(|(_, level)| Level {
                price: level.price,
                size: level.total_size(),
                orders: level.orders.len(),
            })
            .collect();

        let spread = if !bid_levels.is_empty() && !ask_levels.is_empty() {
            ask_levels[0].price - bid_levels[0].price
        } else {
            0.0
        };

        OrderbookSnapshot {
            market_id: self.market_id,
            sequence: self.sequence.load(Ordering::Relaxed),
            timestamp: self.last_update.load(Ordering::Relaxed) as i64,
            bids: bid_levels,
            asks: ask_levels,
            spread,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Level {
    pub price: f64,
    pub size: f64,
    pub orders: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OrderbookSnapshot {
    pub market_id: u16,
    pub sequence: u64,
    pub timestamp: i64,
    pub bids: Vec<Level>,
    pub asks: Vec<Level>,
    pub spread: f64,
}

#[derive(Debug, Deserialize)]
pub struct OrderAction {
    pub action: String,
    pub asset: u16,
    pub order_id: u64,
    pub side: Option<String>,
    pub price: Option<f64>,
    pub size: Option<f64>,
    pub timestamp: Option<i64>,
}

pub struct OrderbookEngine {
    orderbooks: DashMap<u16, Arc<Orderbook>>,
    order_processor: mpsc::Sender<OrderAction>,
}

impl OrderbookEngine {
    pub fn new(market_ids: Vec<u16>) -> (Self, mpsc::Receiver<OrderAction>) {
        let (tx, rx) = mpsc::channel(100_000);
        
        let mut orderbooks = DashMap::new();
        for market_id in market_ids {
            orderbooks.insert(market_id, Arc::new(Orderbook::new(market_id)));
        }

        (
            Self {
                orderbooks,
                order_processor: tx,
            },
            rx,
        )
    }

    pub async fn process_orders(self: Arc<Self>, mut rx: mpsc::Receiver<OrderAction>) {
        while let Some(action) = rx.recv().await {
            if let Some(book) = self.orderbooks.get(&action.asset) {
                match action.action.as_str() {
                    "place" => {
                        if let (Some(side), Some(price), Some(size)) = 
                            (action.side, action.price, action.size) {
                            book.add_order(
                                action.order_id,
                                side == "buy",
                                price,
                                size,
                                action.timestamp.unwrap_or(0),
                            );
                        }
                    }
                    "cancel" => {
                        book.cancel_order(action.order_id);
                    }
                    "modify" => {
                        if let (Some(side), Some(price), Some(size)) = 
                            (action.side, action.price, action.size) {
                            book.cancel_order(action.order_id);
                            book.add_order(
                                action.order_id,
                                side == "buy",
                                price,
                                size,
                                action.timestamp.unwrap_or(0),
                            );
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    pub fn get_orderbook(&self, market_id: u16) -> Option<Arc<Orderbook>> {
        self.orderbooks.get(&market_id).map(|entry| entry.clone())
    }

    pub async fn send_order(&self, action: OrderAction) -> Result<(), mpsc::error::SendError<OrderAction>> {
        self.order_processor.send(action).await
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    info!("Starting Orderbook Engine (Rust)");

    // Initialize engine
    let market_ids = vec![0, 1, 159, 107]; // BTC, ETH, HYPE, ALT
    let (engine, rx) = OrderbookEngine::new(market_ids);
    let engine = Arc::new(engine);

    // Start order processor
    let processor_engine = engine.clone();
    tokio::spawn(async move {
        processor_engine.process_orders(rx).await;
    });

    // Example: Add some orders
    let _ = engine.send_order(OrderAction {
        action: "place".to_string(),
        asset: 159,
        order_id: 1,
        side: Some("buy".to_string()),
        price: Some(34.50),
        size: Some(100.0),
        timestamp: Some(1234567890),
    }).await;

    // Get snapshot
    if let Some(book) = engine.get_orderbook(159) {
        let snapshot = book.get_snapshot(10);
        println!("HYPE Orderbook: {:?}", snapshot);
    }

    // Keep running
    tokio::signal::ctrl_c().await.unwrap();
    info!("Shutting down");
}