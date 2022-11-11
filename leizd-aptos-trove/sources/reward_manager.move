
module leizd_aptos_trove::reward_manager {
    use aptos_framework::coin;
    use std::vector;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_common::permission;
    friend leizd_aptos_trove::trove;
    use std::string::{String};
    use aptos_std::simple_map::{Self, SimpleMap};
    use leizd_aptos_common::coin_key::{key};
    const PRECISION: u64 = 100000000; // TODO
    use aptos_framework::comparator;


    struct LiquidationReward has key, store {
        usdz_reward: u64,
        collateral_rewards: SimpleMap<String, u64>, 
    }

    struct UserRewardSnapshot has key {
        debt: u64,
        rewards: vector<CollateralReward>,
    }

    struct CollateralReward has key, store, copy {
        key: String,
        value: u64
    }

    public(friend) fun initialize(owner: &signer) {
        move_to(owner, LiquidationReward {
            usdz_reward: 0,
            collateral_rewards: simple_map::create<String, u64>(),
        })
    }

    public(friend) fun add_supported_coin<C>(owner: &signer) acquires LiquidationReward, {
        let rewards = borrow_global_mut<LiquidationReward>(permission::owner_address()).collateral_rewards;
        simple_map::add<String, u64>(&mut rewards, key<C>(), 0)
    }

    public(friend) fun upadte_trove_reward_snapshot_of(account: address, key: &String) acquires LiquidationReward, UserRewardSnapshot {
        let owner_addr = permission::owner_address();
        let user_snapshot = borrow_global_mut<UserRewardSnapshot>(account);
        let liquidation_reward = borrow_global<LiquidationReward>(owner_addr);
        user_snapshot.debt = liquidation_reward.usdz_reward;
        let i = 0;
        while(i < vector::length(&user_snapshot.rewards)) {
            let reward = vector::borrow_mut<CollateralReward>(&mut user_snapshot.rewards, i);
            i = i + 1;
            if (!comparator::is_equal(&comparator::compare(key,&reward.key))) {
                continue;
            };
            reward.value = *simple_map::borrow<String, u64>(&borrow_global<LiquidationReward>(owner_addr).collateral_rewards, key);
            return
        }
    }

    fun find_collateral_reward_from_snapshot(account: address, key: &String): u64 acquires UserRewardSnapshot{
        let user_snapshot = borrow_global<UserRewardSnapshot>(account);
        let i = 0;
        while(i < vector::length(&user_snapshot.rewards)) {
            let reward = vector::borrow<CollateralReward>(&user_snapshot.rewards, i);
            i = i + 1;
            if (comparator::is_equal(&comparator::compare(key,&reward.key))) {
                continue;
            };
            return reward.value;
        };
        0
    }

    public fun pending_usdz_reward(account: address, stake_amount: u64): u64 acquires LiquidationReward, UserRewardSnapshot {
        if (stake_amount == 0) {
            return 0;
        };
        let owner_addr = permission::owner_address();
        let user_snapshot = borrow_global<UserRewardSnapshot>(account);
        let liquidation_reward = borrow_global<LiquidationReward>(owner_addr);
        pending_amount(stake_amount, liquidation_reward.usdz_reward, user_snapshot.debt)
    }

    public fun pending_collateral_reward_of(account: address, stake_amount: u64, key: &String): u64 acquires LiquidationReward, UserRewardSnapshot {
        if (stake_amount == 0) {
            return 0;
        };
        let snapshot_amount = find_collateral_reward_from_snapshot(account, key);
        let owner_addr = permission::owner_address();
        let collateral_reward = simple_map::borrow<String, u64>(&borrow_global<LiquidationReward>(owner_addr).collateral_rewards, key);
        pending_amount(stake_amount, *collateral_reward, snapshot_amount)
    }

    fun pending_amount(stake_amount: u64, collateral_amount: u64, user_snapshot_amount: u64): u64 {
        let reward_per_unit_staked = collateral_amount - user_snapshot_amount;
        if (reward_per_unit_staked == 0) {
            return 0;
        };
        stake_amount * reward_per_unit_staked / PRECISION
    }

    public(friend) fun update_system_snapshots(total_stakes: u64, liquidated_collateral: u64, active_collateral: u64, coll_reminder: u64) {

    }

}
