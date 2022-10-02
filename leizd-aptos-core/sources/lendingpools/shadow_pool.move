module leizd::shadow_pool {

    use std::error;
    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_common::pool_status;
    use leizd_aptos_lib::math64;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd::interest_rate;
    use leizd_aptos_logic::risk_factor;
    use leizd::stability_pool;
    use leizd::treasury;

    //// error_code (ref: asset_pool)
    // const ENOT_INITILIZED: u64 = 1;
    const EIS_ALREADY_EXISTED: u64 = 2;
    // const EIS_NOT_EXISTED: u64 = 3;
    const ENOT_AVAILABLE_STATUS: u64 = 4;
    const ENOT_INITIALIZED_COIN: u64 = 5;
    const EAMOUNT_ARG_IS_ZERO: u64 = 11;
    const EEXCEED_BORROWABLE_AMOUNT: u64 = 12;
    const EINSUFFICIENT_LIQUIDITY: u64 = 13;
    const EINSUFFICIENT_CONLY_DEPOSITED: u64 = 14;

    struct ShadowPoolKey has store, drop {} // TODO: remove `drop` ability

    struct Pool has key {
        shadow: coin::Coin<USDZ>
    }

    struct Storage has key {
        total_normal_deposited_amount: u128, // borrowable
        total_conly_deposited_amount: u128, // collateral only
        total_borrowed_amount: u128,
        asset_storages: simple_map::SimpleMap<String, AssetStorage>,
        protocol_fees: u64,
        harvested_protocol_fees: u64,
    }
    struct AssetStorage has store {
        normal_deposited_amount: u64, // borrowable
        normal_deposited_share: u64, // borrowable
        conly_deposited_amount: u64, // collateral only
        conly_deposited_share: u64, // collateral only
        borrowed_amount: u64,
        borrowed_share: u64,
        last_updated: u64,
    }

    // Events
    struct DepositEvent has store, drop {
        key: String,
        caller: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
    }

    struct WithdrawEvent has store, drop {
        key: String,
        caller: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
    }

    struct BorrowEvent has store, drop {
        key: String,
        caller: address,
        borrower: address,
        receiver: address,
        amount: u64,
    }

    struct RepayEvent has store, drop {
        key: String,
        caller: address,
        repay_target: address,
        amount: u64,
    }

    struct LiquidateEvent has store, drop {
        key: String,
        caller: address,
        target: address,
    }

    struct RebalanceEvent has store, drop {
        // caller: address, // TODO: judge use or not use
        from: String,
        to: String,
        amount: u64,
        is_collateral_only_from: bool,
        is_collateral_only_to: bool,
        with_borrow: bool,
    }

    struct SwitchCollateralEvent has store, drop {
        key: String,
        caller: address,
        amount: u64,
        to_collateral_only: bool,
    }

    struct PoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        liquidate_event: event::EventHandle<LiquidateEvent>,
        rebalance_event: event::EventHandle<RebalanceEvent>,
        switch_collateral_event: event::EventHandle<SwitchCollateralEvent>,
    }

    ////////////////////////////////////////////////////
    /// Initialize
    ////////////////////////////////////////////////////
    public entry fun initialize(owner: &signer): ShadowPoolKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert!(!exists<Pool>(owner_addr), error::invalid_argument(EIS_ALREADY_EXISTED));
        move_to(owner, Pool {
            shadow: coin::zero<USDZ>(),
        });
        move_to(owner, default_storage());
        move_to(owner, PoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            liquidate_event: account::new_event_handle<LiquidateEvent>(owner),
            rebalance_event: account::new_event_handle<RebalanceEvent>(owner),
            switch_collateral_event: account::new_event_handle<SwitchCollateralEvent>(owner),
        });
        ShadowPoolKey {}
    }
    fun default_storage(): Storage {
        Storage {
            total_normal_deposited_amount: 0,
            total_conly_deposited_amount: 0,
            total_borrowed_amount: 0,
            asset_storages: simple_map::create<String,AssetStorage>(),
            protocol_fees: 0,
            harvested_protocol_fees: 0,
        }
    }
    //// for assets
    fun init_pool_if_necessary(key: String, storage_ref: &mut Storage) {
        if (!is_initialized_asset_with_internal(&key, storage_ref)) {
            simple_map::add<String,AssetStorage>(&mut storage_ref.asset_storages, key, AssetStorage {
                normal_deposited_amount: 0,
                normal_deposited_share: 0,
                conly_deposited_amount: 0,
                conly_deposited_share: 0,
                borrowed_amount: 0,
                borrowed_share: 0,
                last_updated: 0,
            });
        }
    }

    ////////////////////////////////////////////////////
    /// Deposit
    ////////////////////////////////////////////////////
    public fun deposit_for<C>(
        account: &signer,
        for_address: address, // only use for event
        amount: u64,
        is_collateral_only: bool,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        let key = key<C>();
        deposit_for_internal(key, account, for_address, amount, is_collateral_only)
    }

    public fun deposit_for_with(
        key: String,
        account: &signer,
        for_address: address,
        amount: u64,
        is_collateral_only: bool,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal(key, account, for_address, amount, is_collateral_only)
    }

    fun deposit_for_internal(
        key: String,
        account: &signer,
        for_address: address,
        amount: u64,
        is_collateral_only: bool,
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_deposit_with(key), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        let pool_ref = borrow_global_mut<Pool>(owner_address);

        init_pool_if_necessary(key, storage_ref);
        accrue_interest(key, storage_ref, pool_ref);

        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));

        let asset_storage = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key);
        let user_share: u64;
        if (is_collateral_only) {
            storage_ref.total_conly_deposited_amount = storage_ref.total_conly_deposited_amount + (amount as u128);
            user_share = math64::to_share(amount, asset_storage.conly_deposited_amount, asset_storage.conly_deposited_share);
            asset_storage.conly_deposited_amount = asset_storage.conly_deposited_amount + amount;
            asset_storage.conly_deposited_share = asset_storage.conly_deposited_share + user_share;
        } else {
            storage_ref.total_normal_deposited_amount = storage_ref.total_normal_deposited_amount + (amount as u128);
            user_share = math64::to_share(amount, asset_storage.normal_deposited_amount, asset_storage.normal_deposited_share);
            asset_storage.normal_deposited_amount = asset_storage.normal_deposited_amount + amount;
            asset_storage.normal_deposited_share = asset_storage.normal_deposited_share + user_share;
        };

        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).deposit_event,
            DepositEvent {
                key,
                caller: signer::address_of(account),
                receiver: for_address,
                amount,
                is_collateral_only,
            },
        );

        (amount, user_share)
    }

    ////////////////////////////////////////////////////
    /// Rebalance
    ////////////////////////////////////////////////////
    public fun rebalance_shadow<C1,C2>(
        amount: u64,
        is_collateral_only_C1: bool,
        is_collateral_only_C2: bool,
        _key: &ShadowPoolKey
    ) acquires Storage, PoolEventHandle {
        let key_from = key<C1>();
        let key_to = key<C2>();
        rebalance_shadow_internal(key_from, key_to, amount, is_collateral_only_C1, is_collateral_only_C2)
    }

    fun rebalance_shadow_internal(
        key_from: String,
        key_to: String,
        amount: u64,
        is_collateral_only_C1: bool,
        is_collateral_only_C2: bool,
    ) acquires Storage, PoolEventHandle {
        let owner_addr = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_addr);
        assert!(is_initialized_asset_with_internal(&key_from, storage_ref), error::invalid_argument(ENOT_INITIALIZED_COIN));
        assert!(is_initialized_asset_with_internal(&key_to, storage_ref), error::invalid_argument(ENOT_INITIALIZED_COIN));

        let storage_from = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key_from);
        // TODO: consider share removed
        if (is_collateral_only_C1) {
            storage_from.conly_deposited_amount = storage_from.conly_deposited_amount - amount;
        } else {
            storage_from.normal_deposited_amount = storage_from.normal_deposited_amount - amount;
        };

        let storage_to = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key_to);
        // TODO: consider share added
        if (is_collateral_only_C2) {
            storage_to.conly_deposited_amount = storage_to.conly_deposited_amount + amount;
        } else {
            storage_to.normal_deposited_amount = storage_to.normal_deposited_amount + amount;
        };

        event::emit_event<RebalanceEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_addr).rebalance_event,
            RebalanceEvent {
                from: key_from,
                to: key_to,
                amount,
                is_collateral_only_from: is_collateral_only_C1,
                is_collateral_only_to: is_collateral_only_C2,
                with_borrow: false,
            },
        );
    }

    // with borrow
    public fun borrow_and_rebalance<C1,C2>(amount: u64, is_collateral_only: bool, _key: &ShadowPoolKey) acquires Storage, PoolEventHandle {
        let key_from = key<C1>();
        let key_to = key<C2>();
        borrow_and_rebalance_internal(key_from, key_to, amount, is_collateral_only)
    }

    fun borrow_and_rebalance_internal(key_from: String, key_to: String, amount: u64, is_collateral_only: bool) acquires Storage, PoolEventHandle {
        let owner_addr = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_addr);
        assert!(is_initialized_asset_with_internal(&key_from, storage_ref), error::invalid_argument(ENOT_INITIALIZED_COIN));
        assert!(is_initialized_asset_with_internal(&key_to, storage_ref), error::invalid_argument(ENOT_INITIALIZED_COIN));

        let storage_from = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key_from);
        storage_from.borrowed_amount = storage_from.borrowed_amount + amount;

        let storage_to = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key_to);
        // TODO: consider share
        if (is_collateral_only) {
            storage_to.conly_deposited_amount = storage_to.conly_deposited_amount + amount;
        } else {
            storage_to.normal_deposited_amount = storage_to.normal_deposited_amount + amount;
        };

        event::emit_event<RebalanceEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_addr).rebalance_event,
            RebalanceEvent {
                from: key_from,
                to: key_to,
                amount,
                is_collateral_only_from: is_collateral_only,
                is_collateral_only_to: false,
                with_borrow: true,
            },
        );
    }

    ////////////////////////////////////////////////////
    /// Withdraw
    ////////////////////////////////////////////////////
    public fun withdraw_for<C>(
        depositor_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        let key = key<C>();
        withdraw_for_internal(
            key,
            depositor_addr,
            receiver_addr,
            amount,
            is_collateral_only,
            liquidation_fee
        )
    }

    public fun withdraw_for_with(
        key: String,
        depositor_addr: address,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal(key, depositor_addr, reciever_addr, amount, is_collateral_only, liquidation_fee)
    }

    fun withdraw_for_internal(
        key: String,
        depositor_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_withdraw_with(key), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        accrue_interest(key, storage_ref, pool_ref);
        collect_shadow_fee(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<USDZ>(receiver_addr, coin::extract(&mut pool_ref.shadow, amount_to_transfer));

        assert!(is_initialized_asset_with_internal(&key, storage_ref), error::invalid_argument(ENOT_INITIALIZED_COIN));
        let asset_storage = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key);
        let withdrawn_user_share: u64;
        if (is_collateral_only) {
            storage_ref.total_conly_deposited_amount = storage_ref.total_conly_deposited_amount - (amount as u128);
            withdrawn_user_share = math64::to_share(amount, asset_storage.conly_deposited_amount, asset_storage.conly_deposited_share);
            asset_storage.conly_deposited_amount = asset_storage.conly_deposited_amount - amount;
            asset_storage.conly_deposited_share = asset_storage.conly_deposited_share - withdrawn_user_share;
        } else {
            storage_ref.total_normal_deposited_amount = storage_ref.total_normal_deposited_amount - (amount as u128);
            withdrawn_user_share = math64::to_share(amount, asset_storage.normal_deposited_amount, asset_storage.normal_deposited_share);
            asset_storage.normal_deposited_amount = asset_storage.normal_deposited_amount - amount;
            asset_storage.normal_deposited_share = asset_storage.normal_deposited_share - withdrawn_user_share;
        };

        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).withdraw_event,
            WithdrawEvent {
                key,
                caller: depositor_addr,
                receiver: receiver_addr,
                amount,
                is_collateral_only,
            },
        );

        (amount, withdrawn_user_share)
    }

    ////////////////////////////////////////////////////
    /// Borrow
    ////////////////////////////////////////////////////
    public fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        let key = key<C>();
        borrow_for_internal(key, borrower_addr, receiver_addr, amount)
    }

    public fun borrow_for_with(
        key: String,
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal(key, borrower_addr, receiver_addr, amount)
    }

    fun borrow_for_internal(
        key: String,
        borrower_addr: address,
        receiver_addr: address,
        amount: u64
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_borrow_with(key), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        init_pool_if_necessary(key, storage_ref); // NOTE: because enable to borrow from stability_pool if no deposited
        accrue_interest(key, storage_ref, pool_ref);

        let entry_fee = risk_factor::calculate_entry_fee(amount);
        let total_fee = entry_fee;
        let amount_with_entry_fee = amount + entry_fee;
        let total_liquidity = total_liquidity_internal(pool_ref, storage_ref);

        // check liquidity
        let total_left = if (stability_pool::is_supported(key)) total_liquidity + stability_pool::left() else total_liquidity;
        assert!((amount_with_entry_fee as u128) <= total_left, error::invalid_argument(EEXCEED_BORROWABLE_AMOUNT));

        if ((amount_with_entry_fee as u128) > total_liquidity) {
            // use stability pool
            if (total_liquidity > 0) {
                // extract all from shadow_pool, supply the shortage to borrow from stability pool
                let extracted = coin::extract_all(&mut pool_ref.shadow);
                let borrowing_value_from_stability = amount_with_entry_fee - coin::value(&extracted);
                let borrowed_from_stability = borrow_from_stability_pool(key, receiver_addr, borrowing_value_from_stability);

                // merge coins extracted & distribute calculated values to receiver & shadow_pool
                coin::merge(&mut extracted, borrowed_from_stability);
                let for_entry_fee = coin::extract(&mut extracted, entry_fee);
                coin::deposit<USDZ>(receiver_addr, extracted); // to receiver
                treasury::collect_fee<USDZ>(for_entry_fee); // to treasury (collected fee)

                total_fee = total_fee + stability_pool::calculate_entry_fee(borrowing_value_from_stability);
            } else {
                // when no liquidity in pool, borrow all from stability pool
                let borrowed_from_stability = borrow_from_stability_pool(key, receiver_addr, amount_with_entry_fee);
                let for_entry_fee = coin::extract(&mut borrowed_from_stability, entry_fee);
                coin::deposit<USDZ>(receiver_addr, borrowed_from_stability); // to receiver
                treasury::collect_fee<USDZ>(for_entry_fee); // to treasury (collected fee)

                total_fee = total_fee + stability_pool::calculate_entry_fee(amount_with_entry_fee);
            }
        } else {
            // not use stability pool
            let extracted = coin::extract(&mut pool_ref.shadow, amount);
            coin::deposit<USDZ>(receiver_addr, extracted);
            collect_shadow_fee(pool_ref, entry_fee); // fee to treasury
        };

        // update borrowed stats
        let amount_with_total_fee = amount + total_fee;
        storage_ref.total_borrowed_amount = storage_ref.total_borrowed_amount + (amount_with_total_fee as u128);
        let asset_storage_ref = simple_map::borrow_mut<String, AssetStorage>(&mut storage_ref.asset_storages, &key);
        let user_share = math64::to_share(amount_with_total_fee, asset_storage_ref.borrowed_amount, asset_storage_ref.borrowed_share);
        asset_storage_ref.borrowed_amount = asset_storage_ref.borrowed_amount + amount_with_total_fee;
        asset_storage_ref.borrowed_share = asset_storage_ref.borrowed_share + user_share;

        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).borrow_event,
            BorrowEvent {
                key,
                caller: borrower_addr,
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount,
            },
        );

        (
            amount_with_total_fee, // TODO: only amount
            user_share
        )
    }

    ////////////////////////////////////////////////////
    /// Repay
    ////////////////////////////////////////////////////
    public fun repay<C>(
        account: &signer,
        amount: u64,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        repay_internal(key<C>(), account, amount)
    }

    public fun repay_with(
        key: String,
        account: &signer,
        amount: u64,
        _key: &ShadowPoolKey
    ): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        repay_internal(key, account, amount)
    }

    fun repay_internal(key: String, account: &signer, amount: u64): (u64, u64) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_repay_with(key), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        let pool_ref = borrow_global_mut<Pool>(owner_address);

        accrue_interest(key, storage_ref, pool_ref);

        // at first, repay to stability_pool
        let repaid_to_stability_pool = repay_to_stability_pool(key, account, amount);
        let to_shadow_pool = amount - repaid_to_stability_pool;
        if (to_shadow_pool > 0) {
            let withdrawn = coin::withdraw<USDZ>(account, to_shadow_pool);
            coin::merge(&mut pool_ref.shadow, withdrawn);
        };

        storage_ref.total_borrowed_amount = storage_ref.total_borrowed_amount - (amount as u128);
        let asset_storage_ref = simple_map::borrow_mut<String, AssetStorage>(&mut storage_ref.asset_storages, &key);
        let user_share = math64::to_share(amount, asset_storage_ref.borrowed_amount, asset_storage_ref.borrowed_share);
        asset_storage_ref.borrowed_amount = asset_storage_ref.borrowed_amount - amount;
        asset_storage_ref.borrowed_share = asset_storage_ref.borrowed_share - user_share;

        let account_addr = signer::address_of(account);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).repay_event,
            RepayEvent {
                key,
                caller: account_addr,
                repay_target: account_addr,
                amount,
            },
        );

        (amount, user_share)
    }

    ////////////////////////////////////////////////////
    /// Liquidation
    ////////////////////////////////////////////////////
    public fun withdraw_for_liquidation<C>(
        liquidator_addr: address,
        target_addr: address,
        withdrawing: u64,
        is_collateral_only: bool,
        _key: &ShadowPoolKey
    ) acquires Pool, Storage, PoolEventHandle {
        withdraw_for_liquidation_internal(key<C>(), liquidator_addr, target_addr, withdrawing, is_collateral_only);
    }

    fun withdraw_for_liquidation_internal(
        key: String,
        liquidator_addr: address,
        target_addr: address,
        withdrawing: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        accrue_interest(key, storage_ref, pool_ref);
        let liquidation_fee = risk_factor::calculate_liquidation_fee(withdrawing);
        withdraw_for_internal(key, liquidator_addr, target_addr, withdrawing, is_collateral_only, liquidation_fee);

        event::emit_event<LiquidateEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).liquidate_event,
            LiquidateEvent {
                key,
                caller: liquidator_addr,
                target: target_addr,
            }
        );
    }

    ////////////////////////////////////////////////////
    /// Switch Collateral
    ////////////////////////////////////////////////////
    public fun switch_collateral<C>(caller: address, amount: u64, to_collateral_only: bool, _key: &ShadowPoolKey) acquires Storage, PoolEventHandle {
        switch_collateral_internal(key<C>(), caller, amount, to_collateral_only);
    }

    fun switch_collateral_internal(key: String, caller: address, amount: u64, to_collateral_only: bool) acquires Storage, PoolEventHandle {
        assert!(pool_status::can_switch_collateral_with(key), error::invalid_state(ENOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(EAMOUNT_ARG_IS_ZERO));
        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        let amount_u128 = (amount as u128);
        // TODO: consider share
        if (to_collateral_only) {
            assert!(amount <= normal_deposited_amount_internal(key, storage_ref) - conly_deposit_amount_internal(key, storage_ref), error::invalid_argument(EINSUFFICIENT_LIQUIDITY));
            let asset_storage_ref = simple_map::borrow_mut<String, AssetStorage>(&mut storage_ref.asset_storages, &key);
            asset_storage_ref.conly_deposited_amount = asset_storage_ref.conly_deposited_amount + amount;
            storage_ref.total_conly_deposited_amount = storage_ref.total_conly_deposited_amount + amount_u128;
            asset_storage_ref.normal_deposited_amount = asset_storage_ref.normal_deposited_amount - amount;
            storage_ref.total_normal_deposited_amount = storage_ref.total_normal_deposited_amount - amount_u128;
        } else {
            assert!(amount <= conly_deposit_amount_internal(key, storage_ref), error::invalid_argument(EINSUFFICIENT_CONLY_DEPOSITED));
            let asset_storage_ref = simple_map::borrow_mut<String, AssetStorage>(&mut storage_ref.asset_storages, &key);
            asset_storage_ref.normal_deposited_amount = asset_storage_ref.normal_deposited_amount + amount;
            storage_ref.total_normal_deposited_amount = storage_ref.total_normal_deposited_amount + amount_u128;
            asset_storage_ref.conly_deposited_amount = asset_storage_ref.conly_deposited_amount - amount;
            storage_ref.total_conly_deposited_amount = storage_ref.total_conly_deposited_amount - amount_u128;
        };
        event::emit_event<SwitchCollateralEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).switch_collateral_event,
            SwitchCollateralEvent {
                key,
                caller,
                amount,
                to_collateral_only,
            },
        );
    }

    ////// Internal Logics
    /// Borrow the shadow from the stability pool
    /// use when shadow in this pool become insufficient.
    fun borrow_from_stability_pool(key: String, caller_addr: address, amount: u64): coin::Coin<USDZ> {
        stability_pool::borrow(key, caller_addr, amount)
    }

    /// Repays the shadow to the stability pool
    /// use when shadow has already borrowed from this pool.
    /// @return repaid amount
    fun repay_to_stability_pool(key: String, account: &signer, amount: u64): u64 {
        let borrowed = stability_pool::borrowed(key);
        if (borrowed == 0) {
            return 0
        } else if (borrowed >= (amount as u128)) {
            stability_pool::repay(key, account, amount);
            return amount
        } else {
            stability_pool::repay(key, account, (borrowed as u64));
            return (borrowed as u64)
        }
    }

    /// This function is called on every user action.
    fun accrue_interest(key: String, storage_ref: &mut Storage, pool_ref: &mut Pool){
        let now = timestamp::now_microseconds();
        let asset_storage_ref = simple_map::borrow_mut<String,AssetStorage>(&mut storage_ref.asset_storages, &key);

        // This is the first time
        if (asset_storage_ref.last_updated == 0) {
            asset_storage_ref.last_updated = now;
            return
        };

        if (asset_storage_ref.last_updated == now) {
            return
        };

        let protocol_share_fee = risk_factor::share_fee();
        let rcomp = interest_rate::update_interest_rate(
            key,
            (asset_storage_ref.normal_deposited_amount as u128),
            (asset_storage_ref.borrowed_amount as u128),
            asset_storage_ref.last_updated,
            now,
        );
        let accrued_interest = (asset_storage_ref.borrowed_amount as u128) * rcomp / interest_rate::precision();
        let protocol_share = accrued_interest * (protocol_share_fee as u128) / interest_rate::precision();
        let new_protocol_fees = storage_ref.protocol_fees + (protocol_share as u64);

        let depositors_share = accrued_interest - protocol_share;

        // send support fee when the pool is supported
        if (stability_pool::is_supported(key) && accrued_interest > 0) {
            let generated_support_fee = stability_pool::calculate_support_fee(accrued_interest);
            depositors_share = depositors_share - generated_support_fee;

            let uncollected_support_fee = stability_pool::uncollected_support_fee(key) + generated_support_fee;
            let collected_support_fee: u128;
            // TOOD: check - can use total liquidity? (not for a asset?)
            // HACK: duplicated to total_liquidity_internal
            let liquidity = (coin::value(&pool_ref.shadow) as u128) - storage_ref.total_conly_deposited_amount;
            // let liquidity = total_liquidity_internal(pool_ref, storage_ref);
            if (uncollected_support_fee > liquidity) {
                collected_support_fee = liquidity;
                uncollected_support_fee = uncollected_support_fee - liquidity;
            } else {
                collected_support_fee = uncollected_support_fee;
                uncollected_support_fee = 0;
            };
            let fee_extracted = coin::extract(&mut pool_ref.shadow, (collected_support_fee as u64));
            stability_pool::collect_support_fee(key, fee_extracted, uncollected_support_fee);
        };

        asset_storage_ref.borrowed_amount = asset_storage_ref.borrowed_amount + (accrued_interest as u64);
        storage_ref.total_borrowed_amount = storage_ref.total_borrowed_amount + accrued_interest;
        asset_storage_ref.normal_deposited_amount = asset_storage_ref.normal_deposited_amount + (depositors_share as u64);
        storage_ref.total_normal_deposited_amount = storage_ref.total_normal_deposited_amount + depositors_share;
        storage_ref.protocol_fees = new_protocol_fees;
        asset_storage_ref.last_updated = now;
    }

    fun collect_shadow_fee(pool_ref: &mut Pool, liquidation_fee: u64) {
        let fee_extracted = coin::extract(&mut pool_ref.shadow, liquidation_fee);
        treasury::collect_fee<USDZ>(fee_extracted);
    }

    public fun harvest_protocol_fees<C>() acquires Pool, Storage{
        let storage_ref = borrow_global_mut<Storage>(permission::owner_address());
        let pool_ref = borrow_global_mut<Pool>(permission::owner_address());
        let harvested_fee = (storage_ref.protocol_fees - storage_ref.harvested_protocol_fees as u128);
        if(harvested_fee == 0){
            return
        };
        let liquidity = total_liquidity_internal(pool_ref, storage_ref);
        if(harvested_fee > liquidity){
            harvested_fee = liquidity;
        };
        storage_ref.harvested_protocol_fees = storage_ref.harvested_protocol_fees + (harvested_fee as u64);
        collect_shadow_fee(pool_ref, (harvested_fee as u64));
    }

    ////// View functions
    public fun total_normal_deposited_amount(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_normal_deposited_amount
    }

    public fun total_liquidity(): u128 acquires Pool, Storage {
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global<Pool>(owner_addr);
        let storage_ref = borrow_global<Storage>(owner_addr);
        total_liquidity_internal(pool_ref, storage_ref)
    }
    fun total_liquidity_internal(pool: &Pool, storage: &Storage): u128 {
        (coin::value(&pool.shadow) as u128) - storage.total_conly_deposited_amount
    }

    public fun total_conly_deposited_amount(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_conly_deposited_amount
    }

    public fun total_borrowed_amount(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_borrowed_amount
    }

    fun is_initialized_asset<C>(): bool acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        is_initialized_asset_with_internal(&key<C>(), storage_ref)
    }
    fun is_initialized_asset_with_internal(key: &String, storage_ref: &Storage): bool {
        simple_map::contains_key<String, AssetStorage>(&storage_ref.asset_storages, key)
    }

    public fun normal_deposited_amount<C>(): u64 acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        normal_deposited_amount_internal(key<C>(), storage_ref)
    }
    fun normal_deposited_amount_internal(key: String, storage: &Storage): u64 {
        if (is_initialized_asset_with_internal(&key, storage)) {
            simple_map::borrow<String, AssetStorage>(&storage.asset_storages, &key).normal_deposited_amount
        } else {
            0
        }
    }

    public fun conly_deposited_amount<C>(): u64 acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        conly_deposit_amount_internal(key<C>(), storage_ref)
    }
    fun conly_deposit_amount_internal(key: String, storage: &Storage): u64 {
        if (is_initialized_asset_with_internal(&key, storage)) {
            simple_map::borrow<String, AssetStorage>(&storage.asset_storages, &key).conly_deposited_amount
        } else {
            0
        }
    }

    public fun borrowed_amount<C>(): u64 acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        borrowed_amount_internal(key<C>(), storage_ref)
    }
    fun borrowed_amount_internal(key: String, storage: &Storage): u64 {
        if (is_initialized_asset_with_internal(&key, storage)) {
            simple_map::borrow<String, AssetStorage>(&storage.asset_storages, &key).borrowed_amount
        } else {
            0
        }
    }

    public fun protocol_fees(): u64 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).protocol_fees
    }

    public fun harvested_protocol_fees(): u64 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).harvested_protocol_fees
    }

    // #[test_only]
    // use aptos_std::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_common::system_administrator;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd::asset_pool;
    #[test_only]
    use leizd::pool_manager;
    #[test_only]
    use leizd::test_coin::{Self,WETH,UNI};
    #[test_only]
    use leizd::test_initializer;

    #[test(owner=@leizd)]
    public entry fun test_initialize(owner: &signer) acquires Storage {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        initialize(owner);
        assert!(exists<Pool>(owner_addr), 0);
        assert!(exists<Storage>(owner_addr), 0);
        assert!(exists<PoolEventHandle>(owner_addr), 0);
        let asset_storages = &borrow_global<Storage>(owner_addr).asset_storages;
        assert!(simple_map::length<String,AssetStorage>(asset_storages) == 0, 0);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    public entry fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_initialize_twice(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        initialize(owner);
        initialize(owner);
    }

    #[test_only]
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_initializer::initialize(owner);
        pool_manager::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        initialize(owner);
        asset_pool::initialize(owner);
        pool_manager::add_pool<WETH>(owner);
        pool_manager::add_pool<UNI>(owner);
    }
    // for deposit
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);
        assert!(coin::balance<USDZ>(account_addr) == 1000000, 0);

        deposit_for_internal(key<WETH>(), account, account_addr, 800000, false);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_normal_deposited_amount() == 800000, 0);
        assert!(normal_deposited_amount<WETH>() == 800000, 0);
        assert!(total_liquidity() == 800000, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_same_as_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal(key<WETH>(), account, account_addr, 100, false);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(total_normal_deposited_amount() == 100, 0);
        assert!(normal_deposited_amount<WETH>() == 100, 0);
        assert!(total_liquidity() == 100, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_more_than_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal(key<WETH>(), account, account_addr, 101, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_more_than_once_sequentially_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal(key<WETH>(), account, account_addr, 10, false);
        timestamp::update_global_time_for_test((initial_sec + 90) * 1000 * 1000); // + 90 sec
        deposit_for_internal(key<WETH>(), account, account_addr, 20, false);
        timestamp::update_global_time_for_test((initial_sec + 180) * 1000 * 1000); // + 90 sec
        deposit_for_internal(key<WETH>(), account, account_addr, 30, false);
        assert!(coin::balance<USDZ>(account_addr) == 40, 0);
        assert!(total_liquidity() == 60, 0);
        assert!(total_normal_deposited_amount() == 60, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(normal_deposited_amount<WETH>() == 60, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal(key<WETH>(), account, account_addr, 800000, true);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_liquidity() == 0, 0);
        // assert!(total_deposited() == 0, 0); // TODO: check
        assert!(total_conly_deposited_amount() == 800000, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(normal_deposited_amount<WETH>() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 800000, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal(key<WETH>(), account, account_addr, 700000, false);
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 600000, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_normal_deposited_amount() == 100000, 0);
        assert!(normal_deposited_amount<WETH>() == 100000, 0);
        assert!(total_liquidity() == 100000, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal(key<WETH>(), account, account_addr, 100, false);
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 100, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 100, 0);
        assert!(total_normal_deposited_amount() == 0, 0);
        assert!(normal_deposited_amount<WETH>() == 0, 0);
        assert!(total_liquidity() == 0, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal(key<WETH>(), account, account_addr, 100, false);
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 101, false, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_more_than_once_sequentially_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal(key<WETH>(), account, account_addr, 100, false);
        timestamp::update_global_time_for_test((initial_sec + 330) * 1000 * 1000); // + 5.5 min
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 10, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 660) * 1000 * 1000); // + 5.5 min
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 20, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 990) * 1000 * 1000); // + 5.5 min
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 30, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 60, 0);
        assert!(total_normal_deposited_amount() == 40, 0);
        assert!(normal_deposited_amount<WETH>() == 40, 0);
        assert!(total_liquidity() == 40, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal(key<WETH>(), account, account_addr, 700000, true);
        withdraw_for_internal(key<WETH>(), account_addr, account_addr, 600000, true, 0);

        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_liquidity() == 0, 0);
        // assert!(total_deposited() == 0, 0); // TODO: check
        assert!(total_conly_deposited_amount() == 100000, 0);
        assert!(total_borrowed_amount() == 0, 0);
        assert!(normal_deposited_amount<WETH>() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 100000, 0);
        assert!(borrowed_amount<WETH>() == 0, 0);
    }

    // for borrow
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000000);

        // deposit
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 800000, false);

        // borrow
        let (borrowed, _) = borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 100000);
        assert!(borrowed == 100500, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 100000, 0);
        assert!(total_normal_deposited_amount() == 800000, 0);
        assert!(normal_deposited_amount<UNI>() == 800000, 0);
        assert!(total_liquidity() == 800000 - (100000 + 500), 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<UNI>() == 0, 0);
        assert!(total_borrowed_amount() == 100500, 0);
        assert!(borrowed_amount<UNI>() == 100500, 0);

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance<USDZ>() == 500, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<BorrowEvent>(&event_handle.borrow_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_with_same_as_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1005);

        // deposit
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 1005, false);

        // borrow
        let (borrowed, _) = borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1005, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
        assert!(total_normal_deposited_amount() == 1005, 0);
        assert!(normal_deposited_amount<UNI>() == 1005, 0);
        assert!(total_liquidity() == 0, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(conly_deposited_amount<UNI>() == 0, 0);
        assert!(total_borrowed_amount() == 1005, 0);
        assert!(borrowed_amount<UNI>() == 1005, 0);

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance<USDZ>() == 5, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1005);

        // deposit
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 1005, false);

        // borrow
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 1001); // NOTE: consider fee
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10000 + 5 * 10);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// deposit UNI
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000 + 5 * 10, false);
        //// borrow UNI
        let (borrowed, _) = borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1005, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
        assert!(borrowed_amount<UNI>() == 1000 + 5 * 1, 0);
        let (borrowed, _) = borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 2000);
        assert!(borrowed == 2010, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 3000, 0);
        assert!(borrowed_amount<UNI>() == 3000 + 5 * 3, 0);
        let (borrowed, _) = borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 3000);
        assert!(borrowed == 3015, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 6000, 0);
        assert!(borrowed_amount<UNI>() == 6000 + 5 * 6, 0);
        let (borrowed, _) = borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 4000);
        assert!(borrowed == 4020, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 10000, 0);
        assert!(borrowed_amount<UNI>() == 10000 + 5 * 10, 0);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 10000 + 50);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     // deposit UNI
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000 + 50, false);
    //     // borrow UNI
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
    //     assert!(borrowed<UNI>() == 1000 + 5 * 1, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 500) * 1000 * 1000); // + 250 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 2000);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 3000, 0);
    //     assert!(borrowed<UNI>() == 3000 + 5 * 3, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 750) * 1000 * 1000); // + 250 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 3000);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 6000, 0);
    //     assert!(borrowed<UNI>() == 6000 + 5 * 6, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 1000) * 1000 * 1000); // + 250 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 4000);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 10000, 0);
    //     assert!(borrowed<UNI>() == 10000 + 5 * 10, 0);
    // }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_to_not_borrow_collateral_only(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 150);

        // deposit UNI
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 100, false);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 50, true);
        // borrow UNI
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 120);
    }

    // for repay
    #[test_only]
    fun pool_shadow_value(addr: address): u64 acquires Pool {
        coin::value(&borrow_global<Pool>(addr).shadow)
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10050);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10050, false);
        assert!(pool_shadow_value(owner_address) == 10050, 0);
        assert!(borrowed_amount<UNI>() == 0, 0);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 5000);
        assert!(pool_shadow_value(owner_address) == 10050 - (5000 + 25), 0);
        assert!(borrowed_amount<UNI>() == 5025, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 5000, 0);
        let (repaid_amount, _) = repay_internal(key<UNI>(), borrower, 2000);
        assert!(repaid_amount == 2000, 0);
        assert!(pool_shadow_value(owner_address) == 7025, 0);
        assert!(borrowed_amount<UNI>() == 3025, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 3000, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_with_same_as_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 1005, false);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 1000);
        usdz::mint_for_test(borrower_addr, 5);
        let (repaid_amount, _) = repay_internal(key<UNI>(), borrower, 1005);
        assert!(repaid_amount == 1005, 0);
        assert!(pool_shadow_value(owner_address) == 1005, 0);
        assert!(borrowed_amount<UNI>() == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_with_more_than_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 1005, false);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 250);
        repay_internal(key<UNI>(), borrower, 251);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10050);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10050, false);
        assert!(pool_shadow_value(owner_address) == 10050, 0);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 10000);
        assert!(pool_shadow_value(owner_address) == 0, 0);
        let (repaid_amount, _) = repay_internal(key<UNI>(), borrower, 1000);
        assert!(repaid_amount == 1000, 0);
        assert!(pool_shadow_value(owner_address) == 1000, 0);
        assert!(borrowed_amount<UNI>() == 9050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 9000, 0);
        let (repaid_amount, _) = repay_internal(key<UNI>(), borrower, 2000);
        assert!(repaid_amount == 2000, 0);
        assert!(pool_shadow_value(owner_address) == 3000, 0);
        assert!(borrowed_amount<UNI>() == 7050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 7000, 0);
        let (repaid_amount, _) = repay_internal(key<UNI>(), borrower, 3000);
        assert!(repaid_amount == 3000, 0);
        assert!(pool_shadow_value(owner_address) == 6000, 0);
        assert!(borrowed_amount<UNI>() == 4050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 4000, 0);
        let (repaid_amount, _) = repay_internal(key<UNI>(), borrower, 4000);
        assert!(repaid_amount == 4000, 0);
        assert!(pool_shadow_value(owner_address) == 10000, 0);
        assert!(borrowed_amount<UNI>() == 50, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_repay_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let owner_address = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

    //     // execute
    //     usdz::mint_for_test(depositor_addr, 10050);
    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10050, false);
    //     assert!(pool_shadow_value(owner_address) == 10050, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 80) * 1000 * 1000); // + 80 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 10000);
    //     assert!(pool_shadow_value(owner_address) == 0, 0);

    //     timestamp::update_global_time_for_test((initial_sec + 160) * 1000 * 1000); // + 80 sec
    //     let repaid_amount = repay<UNI>(borrower, 1000);
    //     assert!(repaid_amount == 1000, 0);
    //     assert!(pool_shadow_value(owner_address) == 1000, 0);
    //     assert!(borrowed<UNI>() == 9050, 0);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 9000, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 240) * 1000 * 1000); // + 80 sec
    //     let repaid_amount = repay<UNI>(borrower, 2000);
    //     assert!(repaid_amount == 2000, 0);
    //     assert!(pool_shadow_value(owner_address) == 3000, 0);
    //     assert!(borrowed<UNI>() == 7050, 0);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 7000, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 320) * 1000 * 1000); // + 80 sec
    //     let repaid_amount = repay<UNI>(borrower, 3000);
    //     assert!(repaid_amount == 3000, 0);
    //     assert!(pool_shadow_value(owner_address) == 6000, 0);
    //     assert!(borrowed<UNI>() == 4050, 0);
    //     assert!(coin::balance<USDZ>(borrower_addr) == 4000, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 400) * 1000 * 1000); // + 80 sec
    //     // let repaid_amount = repay<UNI>(borrower, 4000); // TODO: fail here because of ARITHMETIC_ERROR in accrue_interest (Cannot cast u128 to u64)
    //     // assert!(repaid_amount == 4000, 0);
    //     // assert!(pool_shadow_value(owner_address) == 10000, 0);
    //     // assert!(borrowed<UNI>() == 50, 0);
    //     // assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);

    //     let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
    //     assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 3, 0);
    // }

    // for liquidation
    #[test(owner=@leizd,depositor=@0x111,liquidator=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_liquidation(owner: &signer, depositor: &signer, liquidator: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let liquidator_addr = signer::address_of(liquidator);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(liquidator_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(liquidator);
        usdz::mint_for_test(depositor_addr, 1001);

        deposit_for_internal(key<WETH>(), depositor, depositor_addr, 1001, false);
        assert!(pool_shadow_value(owner_address) == 1001, 0);
        assert!(total_normal_deposited_amount() == 1001, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(coin::balance<USDZ>(depositor_addr) == 0, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);

        withdraw_for_liquidation_internal(key<WETH>(), liquidator_addr, liquidator_addr, 1001, false);
        assert!(pool_shadow_value(owner_address) == 0, 0);
        assert!(total_normal_deposited_amount() == 0, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(coin::balance<USDZ>(depositor_addr) == 0, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 995, 0);
        assert!(treasury::balance<USDZ>() == 6, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<LiquidateEvent>(&event_handle.liquidate_event) == 1, 0);
    }

    // for with stability_pool
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_borrow(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 50000);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000 + 50, false);
        assert!(pool_shadow_value(owner_addr) == 10050, 0);
        assert!(borrowed_amount<UNI>() == 0, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
        //// from only shadow_pool
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 5000);
        assert!(pool_shadow_value(owner_addr) == 10050 - (5000 + 25), 0);
        assert!(borrowed_amount<UNI>() == 5025, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        assert!(usdz::balance_of(borrower_addr) == 5000, 0);
        //// from both
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 10000);
        let from_shadow = 5025;
        let from_stability = 10050 - from_shadow;
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == (from_shadow + 26 as u128), 0); // from_shadow + fee calculated by from_shadow
        assert!(stability_pool::left() == (50000 - from_shadow as u128) , 0);
        assert!(borrowed_amount<UNI>() == 5025 + from_shadow + from_stability + 26, 0);
        assert!(usdz::balance_of(borrower_addr) == 15000, 0);
        //// from only stability_pool
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 15000);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed_amount<UNI>() == 15101 + ((15000 + 75) + 76), 0); // (borrowed + fee) + fee calculated by (borrowed + fee)
        assert!(stability_pool::borrowed(key<UNI>()) == 5051 + ((15000 + 75) + 76), 0); // previous + this time
        assert!(stability_pool::left() == (50000 - 5025 - 15075 as u128), 0); // initial - previous - this time
        assert!(usdz::balance_of(borrower_addr) == 30000, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_with_stability_pool_to_borrow_when_not_supported(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 50000);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000 + 50, false);
        assert!(pool_shadow_value(owner_addr) == 10050, 0);
        assert!(borrowed_amount<UNI>() == 0, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        // borrow the amount more than internal_liquidity even though stability pool does not support UNI
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 20000);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_with_stability_pool_to_borrow_with_cannot_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        stability_pool::deposit(depositor, 15);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 25, false);

        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 41);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_with_stability_pool_to_borrow_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     stability_pool::add_supported_pool<UNI>(owner);
    //     stability_pool::update_config(owner, stability_pool::entry_fee(), 0);

    //     let owner_addr = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 100000);

    //     // Prerequisite
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

    //     // execute
    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     //// prepares
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     stability_pool::deposit(depositor, 50000);
    //     timestamp::update_global_time_for_test((initial_sec + 24) * 1000 * 1000); // + 24 sec
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000 + 50, false);
    //     assert!(pool_shadow_value(owner_addr) == 10050, 0);
    //     assert!(borrowed<UNI>() == 0, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 50000, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 0, 0);
    //     //// from only shadow_pool
    //     timestamp::update_global_time_for_test((initial_sec + 48) * 1000 * 1000); // + 24 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
    //     assert!(pool_shadow_value(owner_addr) == 10050 - (5000 + 25), 0);
    //     assert!(borrowed<UNI>() == 5025, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 50000, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 5000, 0);
    //     //// from both
    //     timestamp::update_global_time_for_test((initial_sec + 72) * 1000 * 1000); // + 24 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 10000);
    //     assert!(pool_shadow_value(owner_addr) == 0, 0);
    //     assert!(borrowed<UNI>() == 5025 + (5000 + 25) + (5000 + 25 + 26), 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == (5000 + 25 + 26), 0);
    //     assert!(stability_pool::left() == 50000 - 5025, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 15000, 0);
    //     //// from only stability_pool
    //     timestamp::update_global_time_for_test((initial_sec + 96) * 1000 * 1000); // + 24 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 15000);
    //     assert!(pool_shadow_value(owner_addr) == 0, 0);
    //     assert!(borrowed<UNI>() == 5025 + (5000 + 25) + (5000 + 25 + 26) + (15000 + 75 + 76), 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == (5000 + 25 + 26) + (15000 + 75 + 76), 0);
    //     assert!(stability_pool::left() == 50000 - 5025 - 15075, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 30000, 0);
    // }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);
        stability_pool::update_config(owner, stability_pool::entry_fee(), 0);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10000);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 5000);
        deposit_for_internal(key<UNI>(), depositor, depositor_addr, 1000, false);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 3000);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed_amount<UNI>() == (1000 + 5) + (2000 + 10 + 11), 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 5 + 2000 + 10 + 11, 0);
        assert!(stability_pool::left() == 5000 - (5 + 2000 + 10), 0);
        assert!(usdz::balance_of(borrower_addr) == 3000, 0);
        //// from only stability_pool
        repay_internal(key<UNI>(), borrower, 1800);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed_amount<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == (5 + 2000 + 10 + 11) - 1800, 0);
        assert!(stability_pool::left() == 5000 - (5 + 2000 + 10) + (1800 - 11), 0);
        assert!(usdz::balance_of(borrower_addr) == 1200, 0);
        //// from both
        repay_internal(key<UNI>(), borrower, 1000);
        assert!(pool_shadow_value(owner_addr) == 1000 - 226, 0);
        assert!(borrowed_amount<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800 - 1000, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        assert!(stability_pool::left() == 5000, 0);
        assert!(usdz::balance_of(borrower_addr) == 200, 0);
        //// from only shadow_pool
        repay_internal(key<UNI>(), borrower, 200);
        assert!(pool_shadow_value(owner_addr) == 1000 - 26, 0);
        assert!(borrowed_amount<UNI>() == 5 + 10 + 11, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        assert!(stability_pool::left() == 5000, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_with_stability_pool_to_repay_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     stability_pool::add_supported_pool<UNI>(owner);
    //     stability_pool::update_config(owner, stability_pool::entry_fee(), 0);

    //     let owner_addr = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 10000);

    //     // execute
    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     //// prepares
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     stability_pool::deposit(depositor, 5000);
    //     timestamp::update_global_time_for_test((initial_sec + 11) * 1000 * 1000); // + 11 sec
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 1000, false);
    //     timestamp::update_global_time_for_test((initial_sec + 22) * 1000 * 1000); // + 11 sec
    //     timestamp::update_global_time_for_test((initial_sec + 33) * 1000 * 1000); // + 11 sec
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 3000);
    //     assert!(pool_shadow_value(owner_addr) == 0, 0);
    //     assert!(borrowed<UNI>() == (1000 + 5) + (2000 + 10 + 11), 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 5 + 2000 + 10 + 11, 0);
    //     assert!(stability_pool::left() == 5000 - (5 + 2000 + 10), 0);
    //     assert!(usdz::balance_of(borrower_addr) == 3000, 0);
    //     //// from only stability_pool
    //     timestamp::update_global_time_for_test((initial_sec + 44) * 1000 * 1000); // + 11 sec
    //     repay<UNI>(borrower, 1800);
    //     assert!(pool_shadow_value(owner_addr) == 0, 0);
    //     assert!(borrowed<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == (5 + 2000 + 10 + 11) - 1800, 0);
    //     assert!(stability_pool::left() == 5000 - (5 + 2000 + 10) + (1800 - 11), 0);
    //     assert!(usdz::balance_of(borrower_addr) == 1200, 0);
    //     //// from both
    //     timestamp::update_global_time_for_test((initial_sec + 55) * 1000 * 1000); // + 11 sec
    //     repay<UNI>(borrower, 1000);
    //     assert!(pool_shadow_value(owner_addr) == 1000 - 226, 0);
    //     assert!(borrowed<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800 - 1000, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 5000, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 200, 0);
    //     //// from only shadow_pool
    //     timestamp::update_global_time_for_test((initial_sec + 66) * 1000 * 1000); // + 11 sec
    //     repay<UNI>(borrower, 200);
    //     assert!(pool_shadow_value(owner_addr) == 1000 - 26, 0);
    //     assert!(borrowed<UNI>() == 5 + 10 + 11, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 5000, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 0, 0);
    // }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_open_position_more_than_once(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);
        stability_pool::update_config(owner, stability_pool::entry_fee(), 0);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // check prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(stability_pool::entry_fee() == stability_pool::default_entry_fee(), 0);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 50000);
        //// 1st
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 5000);
        usdz::mint_for_test(borrower_addr, 25 + 26); // fee in shadow + fee in stability
        repay_internal(key<UNI>(), borrower, 5000 + 25 + 26);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        assert!(stability_pool::uncollected_entry_fee<UNI>() == 0, 0);
        //// 2nd
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 10000);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 20000);
        usdz::mint_for_test(borrower_addr, 100 + 101); // fee in shadow + fee in stability for 20000
        usdz::mint_for_test(borrower_addr, 50 + 51); // fee in shadow + fee in stability for 10000
        repay_internal(key<UNI>(), borrower, 20000 + 100 + 101);
        repay_internal(key<UNI>(), borrower, 10000 + 50 + 51);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        //// 3rd
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 10);
        repay_internal(key<UNI>(), borrower, 10);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 20);
        repay_internal(key<UNI>(), borrower, 20);
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 50);
        repay_internal(key<UNI>(), borrower, 40);
        repay_internal(key<UNI>(), borrower, 10);
        usdz::mint_for_test(borrower_addr, 6);
        repay_internal(key<UNI>(), borrower, 6);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        //// still open position
        borrow_for_internal(key<UNI>(), borrower_addr, borrower_addr, 5000);
        assert!(stability_pool::borrowed(key<UNI>()) == 5051, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower1=@0x222,borrower2=@0x333,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_open_multi_position(owner: &signer, depositor: &signer, borrower1: &signer, borrower2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);
        stability_pool::add_supported_pool<WETH>(owner);
        stability_pool::update_config(owner, stability_pool::entry_fee(), 0);

        let depositor_addr = signer::address_of(depositor);
        let borrower1_addr = signer::address_of(borrower1);
        let borrower2_addr = signer::address_of(borrower2);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower1_addr);
        account::create_account_for_test(borrower2_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower1);
        managed_coin::register<USDZ>(borrower2);
        usdz::mint_for_test(depositor_addr, 20000);

        // execute
        stability_pool::deposit(depositor, 10000);
        deposit_for_internal(key<WETH>(), depositor, depositor_addr, 2500, false);
        //// borrow
        borrow_for_internal(key<WETH>(), borrower1_addr, borrower1_addr, 3000);
        assert!(stability_pool::left() == 10000 - (500 + 15), 0);
        assert!(stability_pool::borrowed(key<WETH>()) == (500 + 15) + 3, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        borrow_for_internal(key<WETH>(), borrower2_addr, borrower2_addr, 2000);
        assert!(stability_pool::left() == 10000 - (500 + 15) - (2000 + 10), 0);
        assert!(stability_pool::borrowed(key<WETH>()) == (500 + 15) + 3 + (2000 + 10) + 11, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        borrow_for_internal(key<UNI>(), borrower2_addr, borrower2_addr, 4000);
        assert!(stability_pool::left() == 10000 - (500 + 15) - (2000 + 10) - (4000 + 20), 0);
        assert!(stability_pool::borrowed(key<WETH>()) == (500 + 15) + 3 + (2000 + 10) + 11, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == (4000 + 20) + 21, 0);
        //// repay
        repay_internal(key<UNI>(), depositor, 4041);
        assert!(stability_pool::borrowed(key<WETH>()) == (500 + 15) + 3 + (2000 + 10) + 11, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
        repay_internal(key<WETH>(), depositor, 2539);
        assert!(stability_pool::borrowed(key<WETH>()) == 0, 0);
        assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_support_fee(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     stability_pool::add_supported_pool<UNI>(owner);

    //     let owner_addr = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 10000000);

    //     // Prerequisite
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

    //     // execute
    //     //// prepares
    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000000, false);
    //     assert!(pool_shadow_value(owner_addr) == 10000000, 0);
    //     assert!(borrowed_amount<UNI>() == 0, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     assert!(stability_pool::collected_fee() == 0, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 0, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 1) * 1000 * 1000);
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
    //     assert!(pool_shadow_value(owner_addr) == 10000000 - (1000 + 5), 0);
    //     assert!(borrowed_amount<UNI>() == 1005, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     let liquidity = total_liquidity();
    //     timestamp::update_global_time_for_test((initial_sec + 1 + 1) * 1000 * 1000);
    //     repay<UNI>(borrower, 1);
    //     assert!((pool_shadow_value(owner_addr) as u128) == liquidity - (stability_pool::collected_fee() as u128) + 1, 0);
    //     assert!(stability_pool::collected_fee() > 0, 0);
    //     assert!(stability_pool::total_uncollected_fee() == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 999, 0);
    // }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_support_fee_when_not_supported(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let owner_addr = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 10000000);

    //     // Prerequisite
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

    //     // execute
    //     //// prepares
    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000000, false);
    //     assert!(pool_shadow_value(owner_addr) == 10000000, 0);
    //     assert!(borrowed_amount<UNI>() == 0, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     assert!(stability_pool::collected_fee() == 0, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 0, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 1) * 1000 * 1000);
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
    //     assert!(pool_shadow_value(owner_addr) == 10000000 - (1000 + 5), 0);
    //     assert!(borrowed_amount<UNI>() == 1005, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     let liquidity = total_liquidity();
    //     timestamp::update_global_time_for_test((initial_sec + 1 + 1) * 1000 * 1000);
    //     repay<UNI>(borrower, 1);
    //     assert!((pool_shadow_value(owner_addr) as u128) == liquidity + 1, 0);
    //     assert!(stability_pool::collected_fee() == 0, 0);
    //     assert!(stability_pool::total_uncollected_fee() == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 999, 0);
    // }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //  #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_support_fee_more_than_liquidity(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     stability_pool::add_supported_pool<UNI>(owner);

    //     let owner_addr = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 100000);

    //     // Prerequisite
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

    //     // execute
    //     //// prepares
    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 10000, false);
    //     assert!(pool_shadow_value(owner_addr) == 10000, 0);
    //     assert!(borrowed_amount<UNI>() == 0, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     assert!(stability_pool::collected_fee() == 0, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 0, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 1) * 1000 * 1000);
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
    //     assert!(pool_shadow_value(owner_addr) == 10000 - (5000 + 25), 0);
    //     assert!(borrowed_amount<UNI>() == 5025, 0);
    //     assert!(stability_pool::borrowed(key<UNI>()) == 0, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     let liquidity = total_liquidity();
    //     timestamp::update_global_time_for_test((initial_sec + 1 + 1) * 1000 * 1000);
    //     repay<UNI>(borrower, 1);
    //     assert!(pool_shadow_value(owner_addr) == 1, 0);
    //     assert!((stability_pool::collected_fee() as u128) == liquidity, 0);
    //     assert!(stability_pool::left() == 0, 0);
    //     assert!(usdz::balance_of(borrower_addr) == 4999, 0);
    // }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        managed_coin::register<WETH>(account1);
        managed_coin::register<UNI>(account1);
        managed_coin::register<USDZ>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit_for_internal(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_for_internal(key<UNI>(), account1, account1_addr, 100000, false);
        assert!(normal_deposited_amount<WETH>() == 100000, 0);
        assert!(normal_deposited_amount<UNI>() == 100000, 0);

        rebalance_shadow_internal(key<WETH>(), key<UNI>(), 10000, false, false);
        assert!(normal_deposited_amount<WETH>() == 90000, 0);
        assert!(normal_deposited_amount<UNI>() == 110000, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RebalanceEvent>(&event_handle.rebalance_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow_with_all_pattern(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 50000);
        deposit_for_internal(key<WETH>(), account, account_addr, 10000, false);
        deposit_for_internal(key<WETH>(), account, account_addr, 10000, true);
        deposit_for_internal(key<UNI>(), account, account_addr, 10000, false);
        deposit_for_internal(key<UNI>(), account, account_addr, 10000, true);
        assert!(normal_deposited_amount<WETH>() == 10000, 0);
        assert!(conly_deposited_amount<WETH>() == 10000, 0);
        assert!(normal_deposited_amount<UNI>() == 10000, 0);
        assert!(conly_deposited_amount<UNI>() == 10000, 0);

        // borrowable & borrowable
        rebalance_shadow_internal(key<WETH>(), key<UNI>(), 5000, false, false);
        assert!(normal_deposited_amount<WETH>() == 5000, 0);
        assert!(conly_deposited_amount<WETH>() == 10000, 0);
        assert!(normal_deposited_amount<UNI>() == 15000, 0);
        assert!(conly_deposited_amount<UNI>() == 10000, 0);

        // collateral only & collateral only
        rebalance_shadow_internal(key<WETH>(), key<UNI>(), 5000, true, true);
        assert!(normal_deposited_amount<WETH>() == 5000, 0);
        assert!(conly_deposited_amount<WETH>() == 5000, 0);
        assert!(normal_deposited_amount<UNI>() == 15000, 0);
        assert!(conly_deposited_amount<UNI>() == 15000, 0);

        // borrowable & collateral only
        rebalance_shadow_internal(key<WETH>(), key<UNI>(), 5000, false, true);
        assert!(normal_deposited_amount<WETH>() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 5000, 0);
        assert!(normal_deposited_amount<UNI>() == 15000, 0);
        assert!(conly_deposited_amount<UNI>() == 20000, 0);

        // collateral only & borrowable
        rebalance_shadow_internal(key<WETH>(), key<UNI>(), 5000, true, false);
        assert!(normal_deposited_amount<WETH>() == 0, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);
        assert!(normal_deposited_amount<UNI>() == 20000, 0);
        assert!(conly_deposited_amount<UNI>() == 20000, 0);
    }
    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_rebalance_shadow_to_set_not_added_coin_key_to_from(owner: &signer, aptos_framework: &signer) acquires Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_initializer::initialize(owner);
        pool_manager::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        initialize(owner);
        asset_pool::initialize(owner);
        pool_manager::add_pool<WETH>(owner);

        rebalance_shadow_internal(key<UNI>(), key<WETH>(), 5000, true, true);
    }
    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_rebalance_shadow_to_set_not_added_coin_key_to_to(owner: &signer, aptos_framework: &signer) acquires Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_initializer::initialize(owner);
        pool_manager::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        initialize(owner);
        asset_pool::initialize(owner);
        pool_manager::add_pool<WETH>(owner);

        rebalance_shadow_internal(key<UNI>(), key<WETH>(), 5000, true, true);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(owner_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        // execute
        //// prepares
        deposit_for_internal(key<WETH>(), owner, owner_addr, 100000, false);
        deposit_for_internal(key<UNI>(), account1, account1_addr, 100000, false);
        borrow_for_internal(key<WETH>(), account1_addr, account1_addr, 50000);
        assert!(borrowed_amount<WETH>() == 50000 + 250, 0);
        assert!(normal_deposited_amount<UNI>() == 100000, 0);

        borrow_and_rebalance_internal(key<WETH>(), key<UNI>(), 10000, false);
        assert!(borrowed_amount<WETH>() == 60000 + 250, 0); // WANT: check to charge fee in rebalance (maybe 300)
        assert!(normal_deposited_amount<UNI>() == 110000, 0);

        let event_handle = borrow_global<PoolEventHandle>(owner_addr);
        assert!(event::counter<RebalanceEvent>(&event_handle.rebalance_event) == 1, 0);
    }

    // for switch_collateral
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    public entry fun test_switch_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit_for_internal(key<WETH>(), account, account_addr, 1000, false);
        assert!(total_liquidity() == 1000, 0);
        assert!(total_normal_deposited_amount() == 1000, 0);
        assert!(total_conly_deposited_amount() == 0, 0);
        assert!(normal_deposited_amount<WETH>() == 1000, 0);
        assert!(conly_deposited_amount<WETH>() == 0, 0);

        switch_collateral_internal(key<WETH>(), account_addr, 800, true);
        assert!(total_liquidity() == 200, 0);
        assert!(total_normal_deposited_amount() == 200, 0);
        assert!(total_conly_deposited_amount() == 800, 0);
        assert!(normal_deposited_amount<WETH>() == 200, 0);
        assert!(conly_deposited_amount<WETH>() == 800, 0);
        assert!(event::counter<SwitchCollateralEvent>(&borrow_global<PoolEventHandle>(owner_addr).switch_collateral_event) == 1, 0);

        switch_collateral_internal(key<WETH>(), account_addr, 400, false);
        assert!(total_liquidity() == 600, 0);
        assert!(total_normal_deposited_amount() == 600, 0);
        assert!(total_conly_deposited_amount() == 400, 0);
        assert!(normal_deposited_amount<WETH>() == 600, 0);
        assert!(conly_deposited_amount<WETH>() == 400, 0);
        assert!(event::counter<SwitchCollateralEvent>(&borrow_global<PoolEventHandle>(owner_addr).switch_collateral_event) == 2, 0);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_switch_collateral_when_amount_is_zero(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit_for_internal(key<WETH>(), account, account_addr, 1000, false);
        switch_collateral_internal(key<WETH>(), account_addr, 0, true);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65549)]
    public entry fun test_switch_collateral_to_collateral_only_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit_for_internal(key<WETH>(), account, account_addr, 1000, false);
        switch_collateral_internal(key<WETH>(), account_addr, 1001, true);
    }
    #[test(owner=@leizd, account=@0x111, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65550)]
    public entry fun test_switch_collateral_to_normal_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000);

        deposit_for_internal(key<WETH>(), account, account_addr, 1000, true);
        switch_collateral_internal(key<WETH>(), account_addr, 1001, false);
    }

    // for common validations
    //// `amount` arg
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_deposit_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        deposit_for_internal(key<WETH>(), owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_withdraw_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal(key<WETH>(), owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_borrow_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        borrow_for_internal(key<WETH>(), owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay_internal(key<WETH>(), owner, 0);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        deposit_for_internal(key<WETH>(), owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_froze(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::freeze_pool<WETH>(owner);
        deposit_for_internal(key<WETH>(), owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal(key<WETH>(), owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        borrow_for_internal(key<WETH>(), owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_frozen(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::freeze_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        borrow_for_internal(key<WETH>(), owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        repay_internal(key<WETH>(), owner, 0);
    }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_harvest_protocol_fees(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let owner_address = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 3000000);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
    //     assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

    //     // execute
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 3000000, false);
    //     assert!(pool_shadow_value(owner_address) == 3000000, 0);
    //     assert!(borrowed_amount<UNI>() == 0, 0);
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
    //     assert!(pool_shadow_value(owner_address) == 3000000 - (1000 + 5), 0);
    //     // assert!(borrowed<UNI>() == 1005, 0); // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //     assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     let repaid_amount = repay<UNI>(borrower, 1000);
    //     assert!(repaid_amount == 1000, 0);
    //     assert!(pool_shadow_value(owner_address) == 3000000 - (1000 + 5) + 1000, 0);
    //     // assert!(borrowed<UNI>() == 5, 0); // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //     assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
    //     let total_protocol_fees = protocol_fees();
    //     assert!(total_protocol_fees > 0, 0);
    //     assert!(harvested_protocol_fees() == 0, 0);
    //     let treasury_balance = treasury::balance<USDZ>();
    //     harvest_protocol_fees<UNI>();
    //     assert!(protocol_fees() == total_protocol_fees, 0);
    //     assert!(harvested_protocol_fees() == total_protocol_fees, 0);
    //     assert!(treasury::balance<USDZ>() == treasury_balance + total_protocol_fees, 0);
    //     assert!(pool_shadow_value(owner_address) == 2999995 - total_protocol_fees, 0);

    //     let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
    //     assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    // }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_harvest_protocol_fees_more_than_liquidity(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let owner_address = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 3000000);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
    //     assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

    //     // execute
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 300000, false);
    //     assert!(pool_shadow_value(owner_address) == 300000, 0);
    //     assert!(borrowed_amount<UNI>() == 0, 0);
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
    //     assert!(pool_shadow_value(owner_address) == 300000 - (1000 + 5), 0);
    //     // assert!(borrowed<UNI>() == 1005, 0); // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //     assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     let repaid_amount = repay<UNI>(borrower, 1000);
    //     assert!(repaid_amount == 1000, 0);
    //     assert!(pool_shadow_value(owner_address) == 300000 - (1000 + 5) + 1000, 0);
    //     // assert!(borrowed<UNI>() == 5, 0); // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //     assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
    //     let total_protocol_fees = protocol_fees();
    //     let liquidity = total_liquidity();
    //     assert!(liquidity > 0, 0);
    //     assert!((total_protocol_fees as u128) > liquidity, 0);
    //     assert!(harvested_protocol_fees() == 0, 0);
    //     let treasury_balance = treasury::balance<USDZ>();
    //     harvest_protocol_fees<UNI>();
    //     assert!(protocol_fees() == total_protocol_fees, 0);
    //     assert!((harvested_protocol_fees() as u128) == liquidity, 0);
    //     assert!((treasury::balance<USDZ>() as u128) == (treasury_balance as u128) + liquidity, 0);
    //     assert!((pool_shadow_value(owner_address) as u128) == 299995 - liquidity, 0);

    //     let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
    //     assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    // }
    // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_harvest_protocol_fees_at_zero(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     let owner_address = signer::address_of(owner);
    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<USDZ>(depositor);
    //     managed_coin::register<USDZ>(borrower);
    //     usdz::mint_for_test(depositor_addr, 3000000);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
    //     assert!(risk_factor::share_fee() == risk_factor::default_share_fee(), 0);

    //     // execute
    //     deposit_for_internal(key<UNI>(), depositor, depositor_addr, 3000000, false);
    //     assert!(pool_shadow_value(owner_address) == 3000000, 0);
    //     assert!(borrowed_amount<UNI>() == 0, 0);
    //     borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
    //     assert!(pool_shadow_value(owner_address) == 3000000 - (1000 + 5), 0);
    //     // assert!(borrowed<UNI>() == 1005, 0); // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //     assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     let repaid_amount = repay<UNI>(borrower, 1000);
    //     assert!(repaid_amount == 1000, 0);
    //     assert!(pool_shadow_value(owner_address) == 3000000 - (1000 + 5) + 1000, 0);
    //     // assert!(borrowed<UNI>() == 5, 0); // TODO: fail because of total_borrowed increased by interest_rate (as time passes)
    //     assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
    //     let total_protocol_fees = protocol_fees();
    //     assert!(total_protocol_fees > 0, 0);
    //     assert!(harvested_protocol_fees() == 0, 0);
    //     let treasury_balance = treasury::balance<USDZ>();
    //     harvest_protocol_fees<UNI>();
    //     assert!(protocol_fees() == total_protocol_fees, 0);
    //     assert!(harvested_protocol_fees() == total_protocol_fees, 0);
    //     assert!(treasury::balance<USDZ>() == treasury_balance + total_protocol_fees, 0);
    //     assert!(pool_shadow_value(owner_address) == 2999995 - total_protocol_fees, 0);
    //     // harvest again
    //     treasury_balance = treasury::balance<USDZ>();
    //     let pool_balance = pool_shadow_value(owner_address);
    //     harvest_protocol_fees<UNI>();
    //     assert!(protocol_fees() - harvested_protocol_fees() == 0, 0);
    //     assert!(treasury::balance<USDZ>() == treasury_balance, 0);
    //     assert!(pool_shadow_value(owner_address) == pool_balance, 0);

    //     let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
    //     assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    // }
}
