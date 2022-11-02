module leizd_aptos_trove::collateral_manager {
    use leizd_aptos_common::coin_key;
    use std::string::{String};
    use std::comparator;
    use std::vector;
    use std::signer;
    use leizd_aptos_common::permission;

    friend leizd_aptos_trove::trove;

    struct CoinStatistic has key, store, copy, drop {
        key: String,
        total_deposited: u64
    }

    struct Statistics has key, store {
        total_borrowed: u64,
        total_deposited: vector<CoinStatistic>,
    }

    public(friend) fun initialize(owner: &signer) {
        move_to(owner, Statistics{
            total_borrowed: 0,
            total_deposited: vector::empty<CoinStatistic>()
        });
    }

    fun key_of<C>(): String {
        coin_key::key<C>()
    }

    public(friend) fun add_supported_coin<C>(owner: &signer) acquires Statistics {
        let owner_address = signer::address_of(owner);
        let statistics = borrow_global_mut<Statistics>(owner_address);
        vector::push_back<CoinStatistic>(&mut statistics.total_deposited, CoinStatistic {
            key: key_of<C>(),
            total_deposited: 0,
        });
    }

    public fun coin_length():u64 acquires Statistics {
        let statistics = borrow_global<Statistics>(permission::owner_address());
        vector::length(&statistics.total_deposited)
    }

    public fun deposited(idx: u64): (String, u64) acquires Statistics {
        let stats = vector::borrow<CoinStatistic>(&borrow_global<Statistics>(permission::owner_address()).total_deposited, idx);
        (stats.key, stats.total_deposited)
    }

    public fun total_borrowed(): u64 acquires Statistics {
        borrow_global<Statistics>(permission::owner_address()).total_borrowed
    }

    public(friend) fun update_statistics(key: String, collateral_amount:u64 ,usdz_amount: u64, neg: bool) acquires Statistics {
        let owner_addr = permission::owner_address();
        let stats = borrow_global_mut<Statistics>(owner_addr);
        let i = 0;
        let finish = false;
        while (!finish && i < vector::length(&stats.total_deposited)) {
            let coin_stats = vector::borrow_mut<CoinStatistic>(&mut stats.total_deposited, i);
            if (!comparator::is_equal(&comparator::compare(&coin_stats.key, &key))) {
                i = i + 1;
                continue
            };
            if (!neg) {
                stats.total_borrowed = stats.total_borrowed + usdz_amount;
                coin_stats.total_deposited = coin_stats.total_deposited + collateral_amount;
                finish = true
            } else {
                stats.total_borrowed = stats.total_borrowed - usdz_amount;
                coin_stats.total_deposited = coin_stats.total_deposited - collateral_amount;
                finish = true
            };
        }
    }

}