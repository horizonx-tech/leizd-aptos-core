
module leizd_aptos_trove::reward_maanger {
    use aptos_framework::coin;
    use std::signer;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_common::permission;
    friend leizd_aptos_trove::trove;
    use std::string::{String};
    use aptos_std::simple_map;
    use leizd_aptos_common::coin_key::{key};

    struct LiquidationReward<phantom C> has key {
        reward: coin::Coin<USDZ>,
        debt: coin::Coin<C>,
    }

    struct RewardSnapshot has key {
        reward: u64,
        debt: UserDebt,
    }

    struct UserDebt has key, store {
        debts: simple_map::SimpleMap<String, u64>,
    }

    public(friend) fun add_supported_coin<C>(owner: &signer) {
        move_to(owner, LiquidationReward<C>{
            reward: coin::zero<USDZ>(),
            debt: coin::zero<C>(),
        });
    }

    public fun usdz_reward<C>(): u64 acquires LiquidationReward {
        coin::value(&borrow_global<LiquidationReward<C>>(permission::owner_address()).reward)
    }

    public fun debt<C>(): u64 acquires LiquidationReward {
        coin::value(&borrow_global<LiquidationReward<C>>(permission::owner_address()).debt)
    }

    public(friend) fun update_trove_reards_snapshots<C>(account: &signer) acquires LiquidationReward, RewardSnapshot {
        let account_addr = signer::address_of(account);
        if(!exists<RewardSnapshot>(account_addr)) {
            move_to(account, RewardSnapshot{
                reward: 0,
                debt: UserDebt {
                    debts: simple_map::create<String, u64>(),
                }
            })
        };
        let reward = borrow_global<LiquidationReward<C>>(permission::owner_address());
        let snapshot = borrow_global_mut<RewardSnapshot>(account_addr);
        let key = key<C>();
        if (!simple_map::contains_key(&snapshot.debt.debts, &key)){
            simple_map::add<String, u64>(&mut snapshot.debt.debts, key<C>(), 0);
        };
        let debt = simple_map::borrow_mut<String, u64>(&mut snapshot.debt.debts, &key);
        debt = debt + reward.debt

    }

}
