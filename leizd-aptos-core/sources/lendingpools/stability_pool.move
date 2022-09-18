module leizd::stability_pool {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::type_info;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd::stb_usdz;

    friend leizd::asset_pool;
    friend leizd::shadow_pool;

    const PRECISION: u64 = 1000000000;
    const DEFAULT_ENTRY_FEE: u64 = 1000000000 * 5 / 1000; // 0.5%

    const EALREADY_INITIALIZED: u64 = 1;
    const EINVALID_ENTRY_FEE: u64 = 2;
    const EINVALID_AMOUNT: u64 = 3;
    const EEXCEED_REMAINING_AMOUNT: u64 = 4;
    const ENO_CLAIMABLE_AMOUNT: u64 = 5;
    const EALREADY_ADDED_COIN: u64 = 6;
    const ENOT_INITIALIZED_COIN: u64 = 7;
    const ENOT_ADDED_COIN: u64 = 8;
    const ENOT_SUPPORTED_COIN: u64 = 9;

    struct StabilityPool has key {
        left: coin::Coin<USDZ>,
        total_deposited: u128,
        total_borrowed: u128,
        total_uncollected_fee: u128,
        collected_fee: coin::Coin<USDZ>,
        supported_pools: vector<String>, // e.g. 0x1::module_name::WBTC
    }

    struct Balance<phantom C> has key {
        borrowed: u128,
        uncollected_fee: u128,
    }

    struct Config has key {
        entry_fee: u64, // One time protocol fee for opening a borrow position
    }

    struct DistributionConfig has key {
        emission_per_sec: u64,
        last_updated: u64,
        index: u64,
    }

    struct UserDistribution has key {
        index: u64,
        unclaimed: u64,
        deposited: u64,
    }

    // events
    struct DepositEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct WithdrawEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct BorrowEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct RepayEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct UpdateStateEvent has store, drop {
        old_index: u64,
        new_index: u64,
        emission_per_sec: u64,
        updated_at: u64,
    }
    struct ClaimRewardEvent has store, drop {
        caller: address,
        deposited: u64,
        claimed_amount: u64,
        unclaimed: u64,
    }
    struct UpdateConfigEvent has store, drop {
        caller: address,
        entry_fee: u64,
    }
    struct StabilityPoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        update_state_event: event::EventHandle<UpdateStateEvent>,
        claim_reward_event: event::EventHandle<ClaimRewardEvent>,
        update_config_event: event::EventHandle<UpdateConfigEvent>,
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_pool_initialized(), error::invalid_state(EALREADY_INITIALIZED));

        stb_usdz::initialize(owner);
        move_to(owner, StabilityPool {
            left: coin::zero<USDZ>(),
            total_deposited: 0,
            total_borrowed: 0,
            total_uncollected_fee: 0,
            collected_fee: coin::zero<USDZ>(),
            supported_pools: vector::empty<String>(),
        });
        move_to(owner, Config {
            entry_fee: DEFAULT_ENTRY_FEE
        });
        move_to(owner, DistributionConfig {
            emission_per_sec: 0,
            last_updated: 0,
            index: 0,
        });
        move_to(owner, StabilityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            update_state_event: account::new_event_handle<UpdateStateEvent>(owner),
            claim_reward_event: account::new_event_handle<ClaimRewardEvent>(owner),
            update_config_event: account::new_event_handle<UpdateConfigEvent>(owner),
        });
    }

    public fun is_pool_initialized(): bool {
        exists<StabilityPool>(permission::owner_address())
    }

    public(friend) fun init_pool<C>(owner: &signer) {
        move_to(owner, Balance<C> {
            borrowed: 0,
            uncollected_fee: 0
        });
    }

    public fun default_user_distribution(): UserDistribution {
        UserDistribution {
            index: 0,
            unclaimed: 0,
            deposited: 0,
        }
    }

    public entry fun update_config(owner: &signer, new_entry_fee: u64) acquires Config, StabilityPoolEventHandle {
        assert!(new_entry_fee < PRECISION, error::invalid_argument(EINVALID_ENTRY_FEE));
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);

        let config = borrow_global_mut<Config>(owner_address);
        if(config.entry_fee == new_entry_fee) return;
        config.entry_fee = new_entry_fee;

        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).update_config_event,
            UpdateConfigEvent {
                caller: owner_address,
                entry_fee: new_entry_fee,
            }
        );
    }

    public fun is_supported<C>(): bool acquires StabilityPool {
        let key = generate_key<C>();
        let supported_pools = borrow_global<StabilityPool>(permission::owner_address()).supported_pools;
        vector::contains<String>(&supported_pools, &key)
    }

    public entry fun add_supported_pool<C>(owner: &signer) acquires StabilityPool {
        assert!(!is_supported<C>(), error::invalid_argument(EALREADY_ADDED_COIN));
        assert!(coin::is_coin_initialized<C>(), error::invalid_argument(ENOT_INITIALIZED_COIN));
        permission::assert_owner(signer::address_of(owner));
        let key = generate_key<C>();
        let supported_pools = &mut borrow_global_mut<StabilityPool>(permission::owner_address()).supported_pools;
        vector::push_back<String>(supported_pools, key);
    }

    public entry fun remove_supported_pool<C>(owner: &signer) acquires StabilityPool {
        assert!(is_supported<C>(), error::invalid_argument(ENOT_ADDED_COIN));
        permission::assert_owner(signer::address_of(owner));
        let key = generate_key<C>();
        let supported_pools = &mut borrow_global_mut<StabilityPool>(permission::owner_address()).supported_pools;

        let i = vector::length<String>(supported_pools);
        while (i > 0) {
            i = i - 1;
            if (*vector::borrow<String>(supported_pools, i) == key) {
                return
            }
        };
        vector::remove<String>(supported_pools, i);
    }

    public entry fun deposit(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        if (!exists<UserDistribution>(signer::address_of(account))) {
            move_to(account, default_user_distribution());
        };

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);

        pool_ref.total_deposited = pool_ref.total_deposited + (amount as u128);

        coin::merge(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        let account_addr = signer::address_of(account);
        if (!stb_usdz::is_account_registered(account_addr)) {
            stb_usdz::register(account);
        };
        stb_usdz::mint(account_addr, amount);
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).deposit_event,
            DepositEvent {
                caller: account_addr,
                target_account: account_addr,
                amount
            }
        );
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        assert!(pool_ref.total_deposited >= (amount as u128), error::invalid_argument(EEXCEED_REMAINING_AMOUNT));

        pool_ref.total_deposited = pool_ref.total_deposited - (amount as u128);
        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin::extract(&mut pool_ref.left, amount));
        stb_usdz::burn(account, amount);
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: account_addr,
                target_account: account_addr,
                amount
            }
        );
    }

    public(friend) entry fun borrow<C>(addr: address, amount: u64): coin::Coin<USDZ> acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        assert!(is_supported<C>(), error::invalid_argument(ENOT_SUPPORTED_COIN));
        // TODO:
        // if (!exists<UserDistribution>(signer::address_of(account))) {
        //     move_to(account, UserDistribution { index: 0 });
        // };
        let borrowed = borrow_internal<C>(amount);
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).borrow_event,
            BorrowEvent {
                caller: addr,
                target_account: addr,
                amount
            }
        );
        borrowed
    }
    fun borrow_internal<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Config, Balance {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        let balance_ref = borrow_global_mut<Balance<C>>(owner_address);
        assert!(coin::value<USDZ>(&pool_ref.left) >= amount, error::invalid_argument(EEXCEED_REMAINING_AMOUNT));

        let fee = calculate_entry_fee(amount);
        balance_ref.borrowed = balance_ref.borrowed + (amount as u128) + (fee as u128);
        balance_ref.uncollected_fee = balance_ref.uncollected_fee + (fee as u128);
        pool_ref.total_borrowed = pool_ref.total_borrowed + (amount as u128) + (fee as u128);
        pool_ref.total_uncollected_fee = pool_ref.total_uncollected_fee + (fee as u128);
        coin::extract<USDZ>(&mut pool_ref.left, amount)
    }
    public fun calculate_entry_fee(value: u64): u64 acquires Config {
        let value_mul_by_fee = value * entry_fee();
        let result = value_mul_by_fee / PRECISION;
        if (value_mul_by_fee % PRECISION != 0) result + 1 else result
    }
    public fun entry_fee(): u64 acquires Config {
        borrow_global<Config>(permission::owner_address()).entry_fee
    }

    public(friend) entry fun repay<C>(account: &signer, amount: u64) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        repay_internal<C>(account, amount);
        let account_addr = signer::address_of(account);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).repay_event,
            RepayEvent {
                caller: account_addr,
                target_account: account_addr,
                amount: amount
            }
        );
    }
    fun repay_internal<C>(account: &signer, amount: u64) acquires StabilityPool, Balance {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let balance_ref = borrow_global_mut<Balance<C>>(owner_address);
        assert!((amount as u128) <= balance_ref.borrowed, error::invalid_argument(EINVALID_AMOUNT));

        balance_ref.borrowed = balance_ref.borrowed - (amount as u128);
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        pool_ref.total_borrowed = pool_ref.total_borrowed - (amount as u128);
        if (balance_ref.uncollected_fee > 0) {
            // collect as fees at first
            if (balance_ref.uncollected_fee >= (amount as u128)) {
                // all amount to fee
                balance_ref.uncollected_fee = balance_ref.uncollected_fee - (amount as u128);
                pool_ref.total_uncollected_fee = pool_ref.total_uncollected_fee - (amount as u128);
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, amount));
            } else {
                // complete uncollected fee, and remaining amount to left
                let to_fee = (balance_ref.uncollected_fee as u64);
                let to_left = amount - to_fee;
                balance_ref.uncollected_fee = 0;
                pool_ref.total_uncollected_fee = pool_ref.total_uncollected_fee - (to_fee as u128);
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, to_fee));
                coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, to_left));
            }
        } else {
            // all amount to left
            coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        };
    }

    public entry fun claim_reward(account: &signer, amount: u64) acquires DistributionConfig, UserDistribution, StabilityPool, StabilityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        let account_addr = signer::address_of(account);
        let user_ref = borrow_global<UserDistribution>(account_addr);

        let unclaimed_reward = user_ref.unclaimed;
        let staked_by_user = user_ref.deposited;
        let total_staked = pool_ref.total_deposited;
        let accrued_reward = update_user_asset(account_addr, staked_by_user, (total_staked as u64));
        if (accrued_reward != 0) {
            unclaimed_reward = unclaimed_reward + accrued_reward;
        };
        assert!(unclaimed_reward > 0, error::invalid_argument(ENO_CLAIMABLE_AMOUNT));

        let amount_to_claim = if (amount > unclaimed_reward) unclaimed_reward else amount;
        let user_mut_ref = borrow_global_mut<UserDistribution>(account_addr);
        user_mut_ref.unclaimed = unclaimed_reward - amount_to_claim;

        coin::deposit<USDZ>(account_addr, coin::extract(&mut pool_ref.collected_fee, amount_to_claim));
        event::emit_event<ClaimRewardEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).claim_reward_event,
            ClaimRewardEvent {
                caller: account_addr,
                deposited: staked_by_user,
                claimed_amount: amount_to_claim,
                unclaimed: user_mut_ref.unclaimed,
            }
        );
    }
    fun update_user_asset(addr: address, staked_by_user: u64, total_staked: u64): u64 acquires DistributionConfig, UserDistribution, StabilityPoolEventHandle {
        let config_ref = borrow_global_mut<DistributionConfig>(permission::owner_address());
        let user_ref = borrow_global_mut<UserDistribution>(addr);
        let accrued_reward = 0;
        let new_index = update_asset_state(config_ref, total_staked);
        if (user_ref.index != new_index) {
            accrued_reward = rewards(staked_by_user, new_index, user_ref.index);
        };
        user_ref.index = new_index;
        accrued_reward
    }
    fun update_asset_state(config_ref: &mut DistributionConfig, total_staked: u64): u64 acquires StabilityPoolEventHandle {
        let old_index = config_ref.index;
        let last_updated = config_ref.last_updated;
        let now = timestamp::now_seconds();
        if (now == last_updated) {
            return old_index
        };

        let new_index = asset_index(old_index, config_ref.emission_per_sec, last_updated, total_staked);
        config_ref.last_updated = now;
        if (new_index != old_index) {
            // update index & emit event
            config_ref.index = new_index;
            event::emit_event<UpdateStateEvent>(
                &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).update_state_event,
                UpdateStateEvent {
                    old_index,
                    new_index,
                    emission_per_sec: config_ref.emission_per_sec,
                    updated_at: config_ref.last_updated,
                }
            );
        };
        new_index
    }
    fun asset_index(current_index: u64, emission_per_sec: u64, last_updated: u64, total_balance: u64): u64 {
        let current_timestamp = timestamp::now_seconds();
        let time_delta = current_timestamp - last_updated;
        emission_per_sec * time_delta * PRECISION / total_balance + current_index
    }
    fun rewards(user_balance: u64, reserve_index: u64, user_index: u64): u64 {
         user_balance * (reserve_index - user_index) / PRECISION
    }

    public fun left(): u128 acquires StabilityPool {
        (coin::value<USDZ>(&borrow_global<StabilityPool>(permission::owner_address()).left) as u128)
    }

    public fun collected_fee(): u64 acquires StabilityPool {
        coin::value<USDZ>(&borrow_global<StabilityPool>(permission::owner_address()).collected_fee)
    }

    public fun total_deposited(): u128 acquires StabilityPool {
        borrow_global<StabilityPool>(permission::owner_address()).total_deposited
    }

    public fun total_borrowed(): u128 acquires StabilityPool {
        borrow_global<StabilityPool>(permission::owner_address()).total_borrowed
    }

    public fun total_uncollected_fee(): u128 acquires StabilityPool {
        borrow_global<StabilityPool>(permission::owner_address()).total_uncollected_fee
    }

    public fun borrowed<C>(): u128 acquires Balance {
        borrow_global<Balance<C>>(permission::owner_address()).borrowed
    }

    public fun uncollected_fee<C>(): u128 acquires Balance {
        borrow_global<Balance<C>>(permission::owner_address()).uncollected_fee
    }

    public fun distribution_config(): (u64, u64, u64) acquires DistributionConfig {
        let config = borrow_global<DistributionConfig>(permission::owner_address());
        (config.emission_per_sec, config.last_updated, config.index)
    }

    fun generate_key<C>(): String {
        let coin_type = type_info::type_name<C>();
        coin_type
    }

    // #[test_only]
    // use aptos_framework::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd_aptos_trove::trove_manager;
    #[test_only]
    use leizd::test_coin::{Self,WETH};
    #[test_only]
    public fun default_entry_fee(): u64 {
        DEFAULT_ENTRY_FEE
    }
    // related initialize
    #[test(owner=@leizd)]
    public entry fun test_initialize(owner: &signer) acquires StabilityPool, Config, DistributionConfig {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);

        initialize(owner);

        assert!(exists<StabilityPool>(owner_addr), 0);
        let stability_pool_ref = borrow_global<StabilityPool>(owner_addr);
        assert!(stability_pool_ref.total_deposited == 0, 0);
        assert!(stability_pool_ref.total_borrowed == 0, 0);
        assert!(stability_pool_ref.total_uncollected_fee == 0, 0);

        assert!(exists<Config>(owner_addr), 0);
        let config_ref = borrow_global<Config>(owner_addr);
        assert!(config_ref.entry_fee == DEFAULT_ENTRY_FEE, 0);

        assert!(exists<DistributionConfig>(owner_addr), 0);
        let distribution_config_ref = borrow_global<DistributionConfig>(owner_addr);
        assert!(distribution_config_ref.emission_per_sec == 0, 0);
        assert!(distribution_config_ref.last_updated == 0, 0);
        assert!(distribution_config_ref.index == 0, 0);

        assert!(exists<StabilityPoolEventHandle>(owner_addr), 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 196609)]
    public entry fun test_initialize_twice(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);

        initialize(owner);
        initialize(owner);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_initialize_without_owner(account: &signer) {
        initialize(account);
    }

    #[test_only]
    fun initialize_for_test_to_use_coin(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        trove_manager::initialize(owner);
        initialize(owner);

        test_coin::init_weth(owner);
        init_pool<WETH>(owner);
    }
    // for deposit
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 400000);
        assert!(left() == 400000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(usdz::balance_of(account_addr) == 600000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 400000, 0);

        assert!(event::counter<DepositEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_deposit_with_no_amount(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_not_enough_coin(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit(account, 1001);
    }
    #[test(owner=@leizd, account=@0x111)]
    public entry fun test_deposit_more_than_once_sequentially(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit(account, 100);
        assert!(usdz::balance_of(account_addr) == 900, 0);
        assert!(stb_usdz::balance_of(account_addr) == 100, 0);
        deposit(account, 200);
        assert!(usdz::balance_of(account_addr) == 700, 0);
        assert!(stb_usdz::balance_of(account_addr) == 300, 0);
        deposit(account, 300);
        assert!(usdz::balance_of(account_addr) == 400, 0);
        assert!(stb_usdz::balance_of(account_addr) == 600, 0);
        deposit(account, 400);
        assert!(usdz::balance_of(account_addr) == 0, 0);
        assert!(stb_usdz::balance_of(account_addr) == 1000, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 400000);

        withdraw(account, 300000);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(usdz::balance_of(account_addr) == 900000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 100000, 0);

        assert!(event::counter<WithdrawEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_withdraw_with_no_amount(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit(account, 400000);
        withdraw(account, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_without_any_deposit(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        managed_coin::register<USDZ>(account1);
        managed_coin::register<USDZ>(account2);
        stb_usdz::register(account2);
        usdz::mint_for_test(account1_addr, 400000);

        deposit(account1, 400000);
        withdraw(account2, 300000);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_with_amount_is_total_deposited(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 300000);

        deposit(account, 300000);
        withdraw(account, 300000);

        assert!(usdz::balance_of(account_addr) == 300000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65540)]
    public entry fun test_withdraw_with_amount_is_greater_than_total_deposited(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 300000);

        deposit(account, 300000);
        withdraw(account, 300001);
    }
    #[test(owner=@leizd, account=@0x111)]
    public entry fun test_withdraw_more_than_once_sequentially(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit(account, 1000);
        withdraw(account, 100);
        assert!(usdz::balance_of(account_addr) == 100, 0);
        assert!(stb_usdz::balance_of(account_addr) == 900, 0);
        withdraw(account, 200);
        assert!(usdz::balance_of(account_addr) == 300, 0);
        assert!(stb_usdz::balance_of(account_addr) == 700, 0);
        withdraw(account, 300);
        assert!(usdz::balance_of(account_addr) == 600, 0);
        assert!(stb_usdz::balance_of(account_addr) == 400, 0);
        withdraw(account, 400);
        assert!(usdz::balance_of(account_addr) == 1000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 0, 0);
    }

    // for borrow
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    public entry fun test_borrow(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        // check prerequisite
        assert!(calculate_entry_fee(1000) == 5, 0); // 5%

        // execute
        deposit(account1, 400000);
        let borrowed = borrow<WETH>(account1_addr, 300000);
        coin::deposit(account2_addr, borrowed);

        // assertions
        assert!(total_deposited() == 400000, 0);
        assert!(left() == 100000, 0);
        assert!(total_borrowed() == ((300000 + calculate_entry_fee(300000)) as u128), 0);
        assert!(borrowed<WETH>() == ((300000 + calculate_entry_fee(300000)) as u128), 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
        assert!(usdz::balance_of(account2_addr) == 300000, 0);
        //// event
        assert!(event::counter<BorrowEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).borrow_event) == 1, 0);
    }
    #[test(owner=@leizd, account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_borrow_with_no_amount(owner: &signer, account: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        let coin = borrow<WETH>(account_addr, 0);

        // post_process
        coin::deposit(account_addr, coin);
    }
    #[test(owner=@leizd, account=@0x111)]
    #[expected_failure(abort_code = 65540)]
    public entry fun test_borrow_with_amount_is_greater_than_left(owner: &signer, account: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        let coin = borrow<WETH>(account_addr, 1001);

        // post_process
        coin::deposit(account_addr, coin);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222)]
    public entry fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);

        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 1000000);
        managed_coin::register<USDZ>(borrower);

        // check prerequisite
        assert!(calculate_entry_fee(1000) == 5, 0); // 5%

        // execute
        deposit(depositor, 400000);
        assert!(total_deposited() == 400000, 0);

        let borrowed = borrow<WETH>(depositor_addr, 100000);
        assert!(left() == 300000, 0);
        assert!(total_borrowed() == ((100000 + calculate_entry_fee(100000)) as u128), 0);
        assert!(borrowed<WETH>() == ((100000 + calculate_entry_fee(100000)) as u128), 0);
        coin::deposit(borrower_addr, borrowed);

        let borrowed = borrow<WETH>(depositor_addr, 100000);
        assert!(left() == 200000, 0);
        assert!(total_borrowed() == ((200000 + calculate_entry_fee(200000)) as u128), 0);
        assert!(borrowed<WETH>() == ((200000 + calculate_entry_fee(200000)) as u128), 0);
        coin::deposit(borrower_addr, borrowed);

        let borrowed = borrow<WETH>(depositor_addr, 100000);
        assert!(left() == 100000, 0);
        assert!(total_borrowed() == ((300000 + calculate_entry_fee(300000)) as u128), 0);
        assert!(borrowed<WETH>() == ((300000 + calculate_entry_fee(300000)) as u128), 0);
        coin::deposit(borrower_addr, borrowed);

        let borrowed = borrow<WETH>(depositor_addr, 100000);
        assert!(left() == 0, 0);
        assert!(total_borrowed() == ((400000 + calculate_entry_fee(400000)) as u128), 0);
        assert!(borrowed<WETH>() == ((400000 + calculate_entry_fee(400000)) as u128), 0);
        coin::deposit(borrower_addr, borrowed);
    }

    // for repay
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    public entry fun test_repay(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        // check prerequisite
        assert!(calculate_entry_fee(1000) == 5, 0); // 5%

        // execute
        deposit(account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        repay<WETH>(account2, 200000);

        // check
        assert!(left() == 298500, 0);
        assert!(collected_fee() == 1500, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed() == 101500, 0);
        assert!(borrowed<WETH>() == 101500, 0);
        assert!(usdz::balance_of(account2_addr) == 100000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
        //// event
        assert!(event::counter<RepayEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).repay_event) == 1, 0);
    }
    //// validations
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_repay_with_zero_amount(owner: &signer, account: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        repay<WETH>(account, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_repay_with_amount_is_greater_than_total_borrowed(owner: &signer, account: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(owner_addr, 2000);

        // execute
        deposit(owner, 2000);
        let borrowed = borrow<WETH>(owner_addr, 1000);
        repay<WETH>(account, 1005 + 1);

        // post_process
        coin::deposit(owner_addr, borrowed);
    }
    //// calcuration
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222)]
    public entry fun test_repay_for_confirming_priority(owner: &signer, depositor: &signer, borrower: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 10000);
        managed_coin::register<USDZ>(borrower);

        // check prerequisite
        assert!(calculate_entry_fee(1000) == 5, 0); // 5%

        // execute
        //// add liquidity & borrow
        deposit(depositor, 10000);
        let borrowed = borrow_internal<WETH>(10000);
        coin::deposit(borrower_addr, borrowed);
        assert!(total_deposited() == 10000, 0);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 0, 0);
        assert!(total_borrowed() == 10050, 0);
        assert!(borrowed<WETH>() == 10050, 0);
        assert!(uncollected_fee<WETH>() == 50, 0);
        assert!(total_uncollected_fee() == 50, 0);
        assert!(stb_usdz::balance_of(depositor_addr) == 10000, 0);
        assert!(usdz::balance_of(borrower_addr) == 10000, 0);
        //// repay (take a priority to uncollected_fee)
        repay_internal<WETH>(borrower, 49);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 49, 0);
        assert!(total_borrowed() == 10001, 0);
        assert!(borrowed<WETH>() == 10001, 0);
        assert!(uncollected_fee<WETH>() == 1, 0);
        assert!(total_uncollected_fee() == 1, 0);
        assert!(usdz::balance_of(borrower_addr) == 9951, 0);
        ////// repay to remained uncollected_fee
        repay_internal<WETH>(borrower, 1);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed() == 10000, 0);
        assert!(borrowed<WETH>() == 10000, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 9950, 0);
        //// repay to total_borrowed
        repay_internal<WETH>(borrower, 9900);
        assert!(left() == 9900, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed() == 100, 0);
        assert!(borrowed<WETH>() == 100, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 50, 0);
        ////// repay to remained total_borrowed
        usdz::mint_for_test(borrower_addr, 50);
        repay_internal<WETH>(borrower, 100);
        assert!(left() == 10000, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222)]
    public entry fun test_repay_with_amount_between_total_borrowed_and_uncollected_fee(owner: &signer, depositor: &signer, borrower: &signer) acquires StabilityPool, Config, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 10000);
        managed_coin::register<USDZ>(borrower);

        // check prerequisite
        assert!(calculate_entry_fee(1000) == 5, 0); // 5%

        // execute
        //// add liquidity & borrow
        deposit(depositor, 10000);
        let borrowed = borrow_internal<WETH>(10000);
        coin::deposit(borrower_addr, borrowed);
        assert!(total_deposited() == 10000, 0);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 0, 0);
        assert!(total_borrowed() == 10050, 0);
        assert!(borrowed<WETH>() == 10050, 0);
        assert!(uncollected_fee<WETH>() == 50, 0);
        assert!(total_uncollected_fee() == 50, 0);
        assert!(usdz::balance_of(borrower_addr) == 10000, 0);
        //// repay
        repay_internal<WETH>(borrower, 100);
        assert!(left() == 50, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed() == 9950, 0);
        assert!(borrowed<WETH>() == 9950, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(total_uncollected_fee() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 9900, 0);
    }

    // for claim_reward
    #[test_only]
    fun init_user_distribution_for_test(account: &signer) { // TODO: temp (to be removed)
        move_to(account, default_user_distribution());
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    public entry fun test_claim_reward_temp(owner: &signer, account: &signer, aptos_framework: &signer) acquires Balance, StabilityPool, Config, DistributionConfig, UserDistribution, StabilityPoolEventHandle {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize_for_test_to_use_coin(owner);
        add_supported_pool<WETH>(owner);
        init_user_distribution_for_test(account);
        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<USDZ>(account);

        // prepares (temp)
        //// update config
        let dist_config = borrow_global_mut<DistributionConfig>(owner_addr);
        dist_config.emission_per_sec = 1;
        let user_dist = borrow_global_mut<UserDistribution>(account_addr);
        user_dist.deposited = 1500;
        //// add to collected_fee
        usdz::mint_for_test(owner_addr, 1505);
        deposit(owner, 1500);
        let borrowed = borrow<WETH>(owner_addr, 1000);
        coin::deposit(owner_addr, borrowed);
        repay<WETH>(owner, 1005);
        assert!(borrowed<WETH>() == 0, 0);
        assert!(collected_fee() == 5, 0);
        // prepares
        timestamp::update_global_time_for_test(10 * 1000 * 1000); // + 10 sec

        // execute
        claim_reward(account, 5);
        assert!(usdz::balance_of(account_addr) == 5, 0);
        assert!(event::counter<ClaimRewardEvent>(&borrow_global<StabilityPoolEventHandle>(owner_addr).claim_reward_event) == 1, 0);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_claim_reward_with_no_claimable(owner: &signer, account: &signer, aptos_framework: &signer) acquires StabilityPool, DistributionConfig, UserDistribution, StabilityPoolEventHandle {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize_for_test_to_use_coin(owner);
        init_user_distribution_for_test(account);
        claim_reward(account, 1);
    }
    #[test(owner=@leizd, account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_claim_reward_with_zero_amount(owner: &signer, account: &signer) acquires StabilityPool, DistributionConfig, UserDistribution, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        claim_reward(account, 0);
    }
    //// related functions
    #[test(owner=@leizd, aptos_framework=@aptos_framework, stash=@0x999)]
    fun test_update_asset_state(owner: &signer, aptos_framework: &signer, stash: &signer) acquires StabilityPoolEventHandle {
        let total_staked = 100;
        let emission_per_sec = 10;
        let last_updated_per_sec = 1648738800; // 20220401T00:00:00
        let distribution_config = DistributionConfig {
            emission_per_sec,
            last_updated: last_updated_per_sec,
            index: 0,
        };

        // prepares
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test((last_updated_per_sec + 30) * 1000 * 1000); // + 30 sec
        //// for event
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        move_to(owner, StabilityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            update_state_event: account::new_event_handle<UpdateStateEvent>(owner),
            claim_reward_event: account::new_event_handle<ClaimRewardEvent>(owner),
            update_config_event: account::new_event_handle<UpdateConfigEvent>(owner),
        });

        // execute
        let new_index = update_asset_state(&mut distribution_config, total_staked);
        let expected_new_index = emission_per_sec * 30 * PRECISION / total_staked;
        assert!(new_index == expected_new_index, 0);
        assert!(distribution_config.index == expected_new_index, 0);
        assert!(distribution_config.last_updated == last_updated_per_sec + 30, 0);
        assert!(distribution_config.emission_per_sec == emission_per_sec, 0);
        assert!(event::counter<UpdateStateEvent>(&borrow_global<StabilityPoolEventHandle>(owner_address).update_state_event) == 1, 0);

        // post_process
        move_to(stash, distribution_config);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework, stash=@0x999)]
    fun test_update_asset_state_when_index_is_not_updated(owner: &signer, aptos_framework: &signer, stash: &signer) acquires StabilityPoolEventHandle {
        let total_staked = 100;
        let last_updated_per_sec = 1648738800; // 20220401T00:00:00

        // prepares
        let distribution_config = DistributionConfig {
            emission_per_sec: 0,
            last_updated: last_updated_per_sec,
            index: 0,
        };
        timestamp::set_time_has_started_for_testing(aptos_framework);
        //// for event
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        move_to(owner, StabilityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            update_state_event: account::new_event_handle<UpdateStateEvent>(owner),
            claim_reward_event: account::new_event_handle<ClaimRewardEvent>(owner),
            update_config_event: account::new_event_handle<UpdateConfigEvent>(owner),
        });

        // execute: proceed time, but no emission_per_sec
        timestamp::update_global_time_for_test((last_updated_per_sec + 30) * 1000 * 1000); // + 30 sec
        let index_1 = update_asset_state(&mut distribution_config, total_staked);
        assert!(index_1 == 0, 0);
        assert!(distribution_config.last_updated == last_updated_per_sec + 30, 0);
        assert!(event::counter<UpdateStateEvent>(&borrow_global<StabilityPoolEventHandle>(owner_address).update_state_event) == 0, 0);

        // execute: equal to the calculated result
        let emission_per_sec = 10;
        let duration = 30;
        timestamp::update_global_time_for_test((last_updated_per_sec + 30 + duration) * 1000 * 1000); // + 30 sec
        let pre_calcurated_index = emission_per_sec * duration * PRECISION / total_staked;
        let pre_setted_index = (emission_per_sec * duration * 5)  * PRECISION / (total_staked * 5);
        assert!(pre_calcurated_index == pre_setted_index, 0); // check condition
        distribution_config.index = pre_setted_index;
        let index_2 = update_asset_state(&mut distribution_config, total_staked);
        assert!(index_2 == pre_calcurated_index, 0);
        assert!(distribution_config.last_updated == last_updated_per_sec + 30 + duration, 0);
        assert!(event::counter<UpdateStateEvent>(&borrow_global<StabilityPoolEventHandle>(owner_address).update_state_event) == 0, 0);

        // post_process
        move_to(stash, distribution_config);
    }
    #[test(aptos_framework=@aptos_framework)]
    fun test_rewards_and_asset_index(aptos_framework: &signer) {
        let last_updated_per_sec = 1648738800; // 20220401T00:00:00
        let emission_per_sec = 10;
        let total_balance = 100;

        // prepares
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test((last_updated_per_sec + 30) * 1000 * 1000); // + 30 sec

        // execute
        let index = asset_index(0, emission_per_sec, last_updated_per_sec, total_balance);
        let rewards = rewards(total_balance / 4, index, 0);
        assert!(rewards == emission_per_sec * 30 * 1 / 4, 0); // emission_per_sec * duration * 25% (user balance / total balance)
    }

    // for related configuration
    #[test(owner = @leizd)]
    fun test_update_config(owner: &signer) acquires Config, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);

        update_config(owner, PRECISION * 10 / 1000);
        assert!(entry_fee() == PRECISION * 10 / 1000, 0);

        assert!(event::counter<UpdateConfigEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).update_config_event) == 1, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_update_config_with_not_owner(owner: &signer, account: &signer) acquires Config, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        update_config(account, PRECISION * 10 / 1000);
    }
    #[test(owner = @leizd)]
    #[expected_failure(abort_code = 65538)]
    fun test_update_config_with_fee_as_equal_to_precision(owner: &signer) acquires Config, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        update_config(owner, PRECISION);
    }
    #[test(owner = @leizd)]
    fun test_calculate_entry_fee(owner: &signer) acquires Config, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);

        assert!(calculate_entry_fee(100000) == 500, 0);
        assert!(calculate_entry_fee(100001) == 501, 0);
        assert!(calculate_entry_fee(99999) == 500, 0);
        assert!(calculate_entry_fee(200) == 1, 0);
        assert!(calculate_entry_fee(199) == 1, 0);
        assert!(calculate_entry_fee(1) == 1, 0);
        assert!(calculate_entry_fee(0) == 0, 0);

        update_config(owner, PRECISION * 7 / 1000);
        assert!(calculate_entry_fee(100001) == 701, 0);
        assert!(calculate_entry_fee(100000) == 700, 0);
        assert!(calculate_entry_fee(99999) == 700, 0);
        assert!(calculate_entry_fee(143) == 2, 0);
        assert!(calculate_entry_fee(142) == 1, 0);
        assert!(calculate_entry_fee(1) == 1, 0);
        assert!(calculate_entry_fee(0) == 0, 0);

        update_config(owner, 0);
        assert!(calculate_entry_fee(100000) == 0, 0);
        assert!(calculate_entry_fee(1) == 0, 0);
    }
    #[test(owner = @leizd)]
    fun test_distribution_config(owner: &signer) acquires DistributionConfig {
        account::create_account_for_test(signer::address_of(owner));
        trove_manager::initialize(owner);
        initialize(owner);

        let (emission_per_sec, last_updated ,index) = distribution_config();
        assert!(emission_per_sec == 0, 0);
        assert!(last_updated == 0, 0);
        assert!(index == 0, 0);
    }
}
