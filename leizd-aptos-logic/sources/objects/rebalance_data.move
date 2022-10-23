module leizd_aptos_logic::rebalance_data {
    use std::string::{String};

    struct Rebalanced has copy, drop {
        key: String,
        amount: u64
    }

    public fun key(rebalance: Rebalanced): String {
        rebalance.key
    }

    public fun amount(rebalance: Rebalanced): u64 {
        rebalance.amount
    }

    public fun create(key:String, amount: u64): Rebalanced {
        Rebalanced {
            key,
            amount
        }
    }
}