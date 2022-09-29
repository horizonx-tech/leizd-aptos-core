module leizd_aptos_logic::rebalance {
    use std::string::{String};

    struct Rebalance has copy, drop {
        key: String,
        amount: u64
    }

    public fun key(rebalance: Rebalance): String {
        rebalance.key
    }

    public fun amount(rebalance: Rebalance): u64 {
        rebalance.amount
    }

    public fun create(key:String, amount: u64): Rebalance {
        Rebalance {
            key,
            amount
        }
    }
}