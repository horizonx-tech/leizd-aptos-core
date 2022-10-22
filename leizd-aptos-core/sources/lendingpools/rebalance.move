module leizd_aptos_logic::rebalance {
   use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map::{Self,SimpleMap};
    use aptos_std::event;
    use aptos_framework::account;
    use aptos_framework::coin;
    use leizd_aptos_lib::i128;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_common::pool_status;
    use leizd_aptos_common::pool_type::{Self, Asset, Shadow};
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_external::price_oracle;
    use leizd::asset_pool::{Self, OperatorKey as AssetPoolKey};
    use leizd::shadow_pool::{Self, OperatorKey as ShadowPoolKey};
    use leizd::account_position::{Self, OperatorKey as AccountPositionKey};

    const EALREADY_INITIALIZED: u64 = 1;
    const ENOT_INITIALIZED_COIN: u64 = 2;
    const ENOT_AVAILABLE_STATUS: u64 = 3;
    const ENO_SAFE_POSITION: u64 = 4;
    const ECANNOT_BORROW_ASSET_WITH_REBALANCE: u64 = 11;

    //// resources
    /// access control
    struct OperatorKey has store, drop {}

    // Events
    struct RebalanceEvent has store, drop {
        caller: address,
        coins: vector<String>,
        deposited_amounts: SimpleMap<String, u64>,
        withdrawn_amounts: SimpleMap<String, u64>,
        borrowed_amounts: SimpleMap<String, u64>,
        repaid_amounts: SimpleMap<String, u64>,
    }
    struct RepayEvenlyEvent has store, drop {
        caller: address,
        coins: vector<String>,
        repaid_shares: vector<u64>
    }
    struct FlattenPositionsEvent has store, drop {
        caller: address,
        target: address,
        health_factor: u64,
        sum_rebalanced_deposited: u128,
        sum_rebalanced_withdrawn: u128,
        sum_rebalanced_borrowed: u128,
        sum_rebalanced_repaid: u128,
    }
    struct RebalanceEventHandle has key, store {
        rebalance_event: event::EventHandle<RebalanceEvent>,
        repay_evenly_event: event::EventHandle<RepayEvenlyEvent>,
        flatten_positions_event: event::EventHandle<FlattenPositionsEvent>,
    }
    
    public fun initialize(
        owner: &signer,
    ): OperatorKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        move_to(owner, RebalanceEventHandle {
            rebalance_event: account::new_event_handle<RebalanceEvent>(owner),
            repay_evenly_event: account::new_event_handle<RepayEvenlyEvent>(owner),
            flatten_positions_event: account::new_event_handle<FlattenPositionsEvent>(owner),
        });
        OperatorKey {}
    }

    public fun borrow_asset_with_rebalance<C>(
        account: &signer,
        amount: u64,
        account_position_key: &AccountPositionKey,
        asset_pool_key: &AssetPoolKey,
        shadow_pool_key: &ShadowPoolKey,
        _key: &OperatorKey
    ) acquires RebalanceEventHandle {
        assert!(asset_pool::is_pool_initialized<C>() && shadow_pool::is_initialized_asset<C>(), error::invalid_argument(ENOT_INITIALIZED_COIN));
        assert!(pool_status::can_borrow_asset_with_rebalance<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));

        let account_addr = signer::address_of(account);

        // update interests for pools that may be used
        asset_pool::exec_accrue_interest<C>(asset_pool_key);
        shadow_pool::exec_accrue_interest<C>(shadow_pool_key);
        shadow_pool::exec_accrue_interest_for_selected(account_position::deposited_coins<Shadow>(account_addr), shadow_pool_key); // for deposit, withdraw for rebalance

        // borrow asset for first without checking HF because updating account position & totals in asset_pool
        let (_, share) = asset_pool::borrow_for<C>(account_addr, account_addr, amount, asset_pool_key);
        account_position::borrow_unsafe<C, Asset>(account_addr, share, account_position_key);
        if (account_position::is_safe_shadow_to_asset<C>(account_addr)) {
            return ()
        };

        let (coins_in_stoa, _, balances_in_stoa) = account_position::position<Shadow>(account_addr);
        let unprotected_in_stoa = unprotected_coins(account_addr, coins_in_stoa);
        let (deposited_amounts, borrowed_amounts) = shares_to_amounts_for_shadow_to_asset_pos(unprotected_in_stoa, balances_in_stoa);
        let (sum_extra, sum_insufficient, total_deposited_volume_in_stoa, total_borrowed_volume_in_stoa, deposited_volumes_in_stoa, borrowed_volumes_in_stoa) = sum_extra_and_insufficient_shadow(
            unprotected_in_stoa,
            deposited_amounts,
            borrowed_amounts,
        );
        if (sum_extra >= sum_insufficient) {
            //////////////////////////////////////
            // execute rebalance without borrow
            //////////////////////////////////////
            let optimized_hf = risk_factor::health_factor_of(
                key<USDZ>(),
                total_deposited_volume_in_stoa,
                total_borrowed_volume_in_stoa
            );
            let (amounts_to_deposit, amounts_to_withdraw) = calc_to_optimize_shadow_by_rebalance_without_borrow(
                unprotected_in_stoa,
                optimized_hf,
                deposited_volumes_in_stoa,
                borrowed_volumes_in_stoa
            );
            let empty_map = simple_map::create<String, u64>();
            execute_rebalance(
                account,
                unprotected_in_stoa,
                amounts_to_deposit,
                amounts_to_withdraw,
                empty_map,
                empty_map,
                account_position_key,
                shadow_pool_key
            );
            event::emit_event<RebalanceEvent>(
                &mut borrow_global_mut<RebalanceEventHandle>(permission::owner_address()).rebalance_event,
                RebalanceEvent {
                    caller: account_addr,
                    coins: unprotected_in_stoa,
                    deposited_amounts: amounts_to_deposit,
                    withdrawn_amounts: amounts_to_withdraw,
                    borrowed_amounts: empty_map,
                    repaid_amounts: empty_map,
                },
            );
            return ()
        };

        ///////////////////////////////////
        // execute rebalance with borrow
        ///////////////////////////////////
        // re: update interests for pools that may be used
        shadow_pool::exec_accrue_interest_for_selected(account_position::deposited_coins<Asset>(account_addr), shadow_pool_key); // for borrow, repay shadow for rebalance

        // calculate required_shadow
        // NOTE: count only shadow needed for borrowing specified asset
        let key_for_specified_asset = key<C>();
        let (extra_for_borrowing_asset, insufficient_for_borrowing_asset, _, _) = extra_and_insufficient_shadow(
            key<USDZ>(),
            *simple_map::borrow(&deposited_amounts, &key_for_specified_asset),
            key_for_specified_asset,
            *simple_map::borrow(&borrowed_amounts, &key_for_specified_asset),
        );
        // NOTE: use ltv because AssetToShadow position is controlled by borrow/repay (not deposit/withdraw)
        let numerator_of_required_shadow = ((insufficient_for_borrowing_asset - extra_for_borrowing_asset) as u128) * risk_factor::precision_u128();
        let required_shadow = ((numerator_of_required_shadow / (risk_factor::ltv_of_shadow() as u128)) as u64);

        let (coins_in_atos, _, balances_in_atos) = account_position::position<Asset>(account_addr);
        let unprotected_in_atos = unprotected_coins(account_addr, coins_in_atos);
        let (deposited_amounts_atos, borrowed_amounts_atos) = shares_to_amounts_for_asset_to_shadow_pos(unprotected_in_atos, balances_in_atos);
        let (sum_capacity, _, capacities, _, _, total_borrowed_volume_in_atos, deposited_volumes_in_atos, borrowed_volumes_in_atos) = sum_capacity_and_overdebt_shadow(
            unprotected_in_atos,
            deposited_amounts_atos,
            borrowed_amounts_atos,
        ); // TODO: whether check sum_overdebt or not?
        if (sum_capacity >= required_shadow) {
            // supply shadow deficiency by borrowing
            let borrowings = make_up_for_required_shadow_by_borrow(
                unprotected_in_atos,
                required_shadow,
                capacities,
                &mut borrowed_amounts_atos,
                &mut borrowed_volumes_in_atos,
            );
            let required_shadow_volume = price_oracle::volume(&key<USDZ>(), (required_shadow as u128));
            total_borrowed_volume_in_atos = total_borrowed_volume_in_atos + required_shadow_volume;
            total_borrowed_volume_in_atos;
            //// borrow from shadow_pool for required_shadow & update account_position
            let i = 0;
            while (i < simple_map::length(&borrowings)) {
                let key = vector::borrow(&unprotected_in_atos, i);
                if (simple_map::contains_key(&borrowings, key)) {
                    let amount = simple_map::borrow(&borrowings, key);
                    let (_, share) = shadow_pool::borrow_for_with(*key, account_addr, account_addr, *amount, shadow_pool_key);
                    account_position::borrow_unsafe_with<Shadow>(*key, account_addr, share, account_position_key);
                };
                i = i + 1;
            };

            // optimize AssetToShadow position (including borrowing USDZ)
            let optimized_hf_for_atos = risk_factor::health_factor_weighted_average_by_map(
                unprotected_in_atos,
                deposited_volumes_in_atos,
                borrowed_volumes_in_atos
            );
            let (amounts_to_borrow, amounts_to_repay) = calc_to_optimize_shadow_by_borrow_and_repay_for_asset_to_shadow_pos(
                unprotected_in_atos,
                optimized_hf_for_atos,
                deposited_volumes_in_atos,
                borrowed_volumes_in_atos
            );

            // optimize ShadowToAsset position
            // NOTE: exec if all position in ShadowToAsset can be healthy, otherwise only deposit for borrowing specified asset
            let amounts_to_deposit = simple_map::create<String, u64>();
            let amounts_to_withdraw = simple_map::create<String, u64>();
            if ((sum_extra as u128) + required_shadow_volume > (sum_insufficient as u128)) {
                // rebalance all positions in ShadowToAsset
                let optimized_hf_for_stoa = risk_factor::health_factor_of(
                    key<USDZ>(),
                    total_deposited_volume_in_stoa + (required_shadow_volume as u128),
                    total_borrowed_volume_in_stoa
                );
                (amounts_to_deposit, amounts_to_withdraw) = calc_to_optimize_shadow_by_rebalance_without_borrow(
                    unprotected_in_stoa,
                    optimized_hf_for_stoa,
                    deposited_volumes_in_stoa,
                    borrowed_volumes_in_stoa
                );
            } else {
                // only deposit for borrowing specified asset
                simple_map::add(
                    &mut amounts_to_deposit,
                    key_for_specified_asset,
                    required_shadow
                );
            };

            // execute_rebalance
            let unprotected_in_both_atos_and_stoa = copy unprotected_in_stoa;
            let j = 0;
            while (j < vector::length(&unprotected_in_atos)) {
                let key = vector::borrow(&unprotected_in_atos, j);
                if (!vector::contains(&unprotected_in_both_atos_and_stoa, key)) {
                    vector::push_back(&mut unprotected_in_both_atos_and_stoa, *key);
                };
                j = j + 1;
            };
            execute_rebalance(
                account,
                unprotected_in_both_atos_and_stoa,
                amounts_to_deposit,
                amounts_to_withdraw,
                amounts_to_borrow,
                amounts_to_repay,
                account_position_key,
                shadow_pool_key
            );
            event::emit_event<RebalanceEvent>(
                &mut borrow_global_mut<RebalanceEventHandle>(permission::owner_address()).rebalance_event,
                RebalanceEvent {
                    caller: account_addr,
                    coins: unprotected_in_stoa,
                    deposited_amounts: amounts_to_deposit,
                    withdrawn_amounts: amounts_to_withdraw,
                    borrowed_amounts: amounts_to_borrow,
                    repaid_amounts: amounts_to_repay,
                },
            );
            return ()
        };

        abort error::invalid_argument(ECANNOT_BORROW_ASSET_WITH_REBALANCE)
    }

    /// repay_shadow_evenly
    public fun repay_shadow_evenly(
        account: &signer,
        amount: u64,
        account_position_key: &AccountPositionKey, 
        shadow_pool_key: &ShadowPoolKey, 
        _key: &OperatorKey
    ) acquires RebalanceEventHandle {
        assert!(pool_status::can_repay_shadow_evenly(), error::invalid_state(ENOT_AVAILABLE_STATUS));
        let account_addr = signer::address_of(account);

        let (target_keys, target_borrowed_shares) = account_position::borrowed_shadow_share_all(account_addr); // get all shadow borrowed_share
        let length = vector::length(&target_keys);
        if (length == 0) return;
        shadow_pool::exec_accrue_interest_for_selected(target_keys, shadow_pool_key); // update shadow pool status
        let (borrowed_amounts, borrowed_total_amount) = borrowed_shares_to_amounts_for_shadow(target_keys, target_borrowed_shares); // convert `share` to `amount`

        // repay to shadow_pools
        let i = 0;
        let repaid_shares = vector::empty<u64>();
        if (amount >= borrowed_total_amount) {
            // repay in full, if input is greater than or equal to total borrowed amount
            while (i < length) {
                let (_, repaid_share) = shadow_pool::repay_by_share_with(
                    *vector::borrow<String>(&target_keys, i),
                    account,
                    *vector::borrow<u64>(&target_borrowed_shares, i),
                    shadow_pool_key
                );
                vector::push_back(&mut repaid_shares, repaid_share);
                i = i + 1;
            };
        } else {
            // repay the same amount, if input is less than total borrowed amount
            let amount_per_pool = amount / length;
            while (i < length) {
                let repaid_share: u64;
                let key = vector::borrow<String>(&target_keys, i);
                let borrowed_amount = vector::borrow<u64>(&borrowed_amounts, i);
                if (amount_per_pool < *borrowed_amount) {
                    (_, repaid_share) = shadow_pool::repay_with(*key, account, amount_per_pool, shadow_pool_key);
                } else {
                    (_, repaid_share) = shadow_pool::repay_by_share_with(
                        *key,
                        account,
                        *vector::borrow<u64>(&target_borrowed_shares, i),
                        shadow_pool_key
                    );
                };
                vector::push_back(&mut repaid_shares, repaid_share);
                i = i + 1;
            };
        };

        // update account_position
        let j = 0;
        while (j < length) {
            account_position::repay_shadow_with(
                *vector::borrow<String>(&target_keys, j),
                account_addr,
                *vector::borrow<u64>(&repaid_shares, j),
                account_position_key
            );
            j = j + 1;
        };

        event::emit_event<RepayEvenlyEvent>(
            &mut borrow_global_mut<RebalanceEventHandle>(permission::owner_address()).repay_evenly_event,
            RepayEvenlyEvent {
                caller: account_addr,
                coins: target_keys,
                repaid_shares: repaid_shares,
            },
        );
    }

    //// Liquidation
    public fun liquidate<C,P>(
        account: &signer,
        target_addr: address,
        account_position_key: &AccountPositionKey,
        asset_pool_key: &AssetPoolKey,
        shadow_pool_key: &ShadowPoolKey, 
        _key: &OperatorKey
    ) acquires RebalanceEventHandle {
        assert!(pool_status::can_liquidate<C>(), error::invalid_state(ENOT_AVAILABLE_STATUS));

        pool_type::assert_pool_type<P>();
        let liquidator_addr = signer::address_of(account);

        if (pool_type::is_type_asset<P>()) {
            // judge if the coin should be liquidated
            assert!(!account_position::is_safe_asset_to_shadow<C>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
    
            if (!account_position::is_protected<C>(target_addr)) {
                flatten_positions(liquidator_addr, target_addr, account_position_key, shadow_pool_key);
            };
            
            if (!account_position::is_safe_asset_to_shadow<C>(target_addr)) {
                // execute liquidation (repay + withdraw)
                let (deposited_amount, is_collateral_only) = account_position::deposited_asset_amount<C>(target_addr);
                let user_share_all = account_position::repay_all_for_liquidation<C,P>(target_addr, account_position_key);
                shadow_pool::repay_by_share<C>(account, user_share_all, shadow_pool_key);
                let (_, withdrawed_user_share) = asset_pool::withdraw_for_liquidation<C>(liquidator_addr, target_addr, deposited_amount, is_collateral_only, asset_pool_key);
                account_position::withdraw<C,P>(target_addr, withdrawed_user_share, is_collateral_only, account_position_key);
            };
        } else {
            // judge if the coin should be liquidated
            assert!(!account_position::is_safe_shadow_to_asset<C>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
            
            if (!account_position::is_protected<C>(target_addr)) {
                flatten_positions(liquidator_addr, target_addr, account_position_key, shadow_pool_key);
            };

            if (!account_position::is_safe_shadow_to_asset<C>(target_addr)) {
                // execute liquidation (repay + withdraw)
                let (deposited_amount, is_collateral_only) = account_position::deposited_shadow_amount<C>(target_addr);
                let user_share_all = account_position::repay_all_for_liquidation<C,P>(target_addr, account_position_key);
                asset_pool::repay_by_share<C>(account, user_share_all, asset_pool_key);
                let (_, withdrawed_user_share) = shadow_pool::withdraw_for_liquidation<C>(target_addr, liquidator_addr, deposited_amount, is_collateral_only, shadow_pool_key);
                account_position::withdraw<C,P>(target_addr, withdrawed_user_share, is_collateral_only, account_position_key);
            };
        };
    }


    fun unprotected_coins(addr: address, coins: vector<String>): vector<String> {
        let unprotected = vector::empty<String>();
        let i = 0;
        while (i < vector::length(&coins)) {
            let coin = vector::borrow(&coins, i);
            if (!account_position::is_protected_with(*coin, addr)){
                vector::push_back(&mut unprotected, *coin);
            };
            i = i + 1;
        };
        unprotected
    }

    //// for ShadowToAsset position
    fun shares_to_amounts_for_shadow_to_asset_pos(keys: vector<String>, balances: SimpleMap<String, account_position::Balance>): (
        SimpleMap<String, u64>, // deposited amounts
        SimpleMap<String, u64> // borrowed amounts
    ) {
        let i = 0;
        let deposited = simple_map::create<String, u64>();
        let borrowed = simple_map::create<String, u64>();
        while (i < vector::length(&keys)) {
            let key = vector::borrow<String>(&keys, i);
            if (simple_map::contains_key(&balances, key)) {
                let (normal_deposited_share, conly_deposited_share, borrowed_share) = account_position::balance_value(simple_map::borrow(&balances, key));
                let normal_deposited_amount = shadow_pool::normal_deposited_share_to_amount(
                    *key,
                    normal_deposited_share,
                );
                let conly_deposited_amount = shadow_pool::conly_deposited_share_to_amount(
                    *key,
                    conly_deposited_share,
                );
                simple_map::add(&mut deposited, *key, ((normal_deposited_amount + conly_deposited_amount) as u64)); // TODO: check type (u64?u128?)

                let borrowed_amount = asset_pool::borrowed_share_to_amount(
                    *key,
                    borrowed_share,
                );
                simple_map::add(&mut borrowed, *key, (borrowed_amount as u64)); // TODO: check type (u64?u128?)
            };
            i = i + 1;
        };
        (deposited, borrowed)
    }
    fun sum_extra_and_insufficient_shadow(
        keys: vector<String>,
        deposited_amounts: SimpleMap<String, u64>,
        borrowed_amounts: SimpleMap<String, u64>
    ): (
        u64, // sum extra
        u64, // sum insufficient
        u128, // total deposited volume
        u128, // total borrowed volume
        SimpleMap<String, u128>, // deposited volumes
        SimpleMap<String, u128>, // borrowed volumes
    ) {
        let sum_extra = 0;
        let sum_insufficient = 0;
        let total_deposited_volume = 0;
        let total_borrowed_volume = 0;
        let deposited_volumes = simple_map::create<String, u128>();
        let borrowed_volumes = simple_map::create<String, u128>();

        let i = 0;
        while (i < vector::length(&keys)) {
            let key = vector::borrow(&keys, i);
            let (extra, insufficient, deposited_volume, borrowed_volume) = extra_and_insufficient_shadow(
                key<USDZ>(),
                *simple_map::borrow(&deposited_amounts, key),
                *key,
                *simple_map::borrow(&borrowed_amounts, key),
            );
            sum_extra = sum_extra + extra;
            sum_insufficient = sum_insufficient + insufficient;
            total_deposited_volume = total_deposited_volume + deposited_volume;
            total_borrowed_volume = total_borrowed_volume + borrowed_volume;
            simple_map::add(&mut deposited_volumes, *key, deposited_volume);
            simple_map::add(&mut borrowed_volumes, *key, borrowed_volume);
            i = i + 1;
        };
        (sum_extra, sum_insufficient, total_deposited_volume, total_borrowed_volume, deposited_volumes, borrowed_volumes)
    }
    fun extra_and_insufficient_shadow(
        deposited_key: String,
        deposited_amount: u64,
        borrowed_key: String,
        borrowed_amount: u64
    ): (
        u64, // extra amount
        u64, // insufiicient amount
        u128, // deposited_volume
        u128, // borrowed_volume
    ) {
        let deposited_volume = price_oracle::volume(&deposited_key, (deposited_amount as u128));
        let borrowed_volume = price_oracle::volume(&borrowed_key, (borrowed_amount as u128));
        // NOTE: use ltv because AssetToShadow position is controlled by borrow/repay (not deposit/withdraw)
        let borrowable_volume = deposited_volume * (risk_factor::ltv_of(deposited_key) as u128) / risk_factor::precision_u128();
        let extra_amount: u64;
        let insufficient_amount: u64;
        if (borrowable_volume > borrowed_volume) {
            extra_amount = (price_oracle::to_amount(&deposited_key, borrowable_volume - borrowed_volume) as u64); // TODO: temp cast (maybe use u128 as return value)
            insufficient_amount = 0;
        } else if (borrowable_volume < borrowed_volume) {
            extra_amount = 0;
            insufficient_amount = (price_oracle::to_amount(&deposited_key, borrowed_volume - borrowable_volume) as u64); // TODO: temp cast (maybe use u128 as return value)
        } else {
            extra_amount = 0;
            insufficient_amount = 0;
        };
        (
            extra_amount,
            insufficient_amount,
            deposited_volume,
            borrowed_volume
        )
    }
    fun calc_to_optimize_shadow_by_rebalance_without_borrow(
        coins: vector<String>,
        optimized_hf: u64,
        deposited_volumes: SimpleMap<String, u128>,
        borrowed_volumes: SimpleMap<String, u128>
    ): (
        SimpleMap<String, u64>, // amounts to deposit
        SimpleMap<String, u64>, // amounts to withdraw
    ) {
        let i = 0;
        let usdz_key = key<USDZ>();
        let amounts_to_deposit = simple_map::create<String, u64>();
        let amounts_to_withdraw = simple_map::create<String, u64>();
        while (i < vector::length<String>(&coins)) {
            let key = vector::borrow(&coins, i);
            let deposited_volume = simple_map::borrow(&deposited_volumes, key);
            let borrowed_volume = simple_map::borrow(&borrowed_volumes, key);
            let current_hf = risk_factor::health_factor_of(
                usdz_key,
                *deposited_volume,
                *borrowed_volume,
            ); // for ShadowToAsset position
            // deposited + delta = borrowed_volume / (LTV * (1 - optimized_hf))
            let precision_u128 = risk_factor::precision_u128();
            let opt_deposit_volume = (*borrowed_volume * precision_u128 / (precision_u128 - (optimized_hf as u128))) // borrowed volume / (1 - optimized_hf)
                * precision_u128 / (risk_factor::lt_of_shadow() as u128); // * (1 / LT)
            if (current_hf > optimized_hf) {
                simple_map::add(
                    &mut amounts_to_withdraw,
                    *key,
                    (price_oracle::to_amount(&usdz_key, *deposited_volume - opt_deposit_volume) as u64) // TODO: temp cast (maybe use u128 as return value)
                );
            } else if (current_hf < optimized_hf) {
                simple_map::add(
                    &mut amounts_to_deposit,
                    *key,
                    (price_oracle::to_amount(&usdz_key, opt_deposit_volume - *deposited_volume) as u64) // TODO: temp cast (maybe use u128 as return value)
                );
            };
            i = i + 1;
        };
        (amounts_to_deposit, amounts_to_withdraw)
    }
    //// for AssetToShadow position
    fun shares_to_amounts_for_asset_to_shadow_pos(keys: vector<String>, balances: SimpleMap<String, account_position::Balance>): (
        SimpleMap<String, u64>, // deposited amounts
        SimpleMap<String, u64>, // borrowed amounts
    ) {
        let i = 0;
        let deposited = simple_map::create<String, u64>();
        let borrowed = simple_map::create<String, u64>();
        while (i < vector::length(&keys)) {
            let key = vector::borrow<String>(&keys, i);
            if (simple_map::contains_key(&balances, key)) {
                let (normal_deposited_share, conly_deposited_share, borrowed_share) = account_position::balance_value(simple_map::borrow(&balances, key));
                let normal_deposited_amount = asset_pool::normal_deposited_share_to_amount(
                    *key,
                    normal_deposited_share,
                );
                let conly_deposited_amount = asset_pool::conly_deposited_share_to_amount(
                    *key,
                    conly_deposited_share,
                );
                simple_map::add(&mut deposited, *key, ((normal_deposited_amount + conly_deposited_amount) as u64)); // TODO: check type (u64?u128?)

                let borrowed_amount = shadow_pool::borrowed_share_to_amount(
                    *key,
                    borrowed_share,
                );
                simple_map::add(&mut borrowed, *key, (borrowed_amount as u64)); // TODO: check type (u64?u128?)
            };
            i = i + 1;
        };
        (deposited, borrowed)
    }
    fun sum_capacity_and_overdebt_shadow(
        keys: vector<String>,
        deposited_amounts: SimpleMap<String, u64>,
        borrowed_amounts: SimpleMap<String, u64>
    ): (
        u64, // sum capacity
        u64, // sum overdebt
        SimpleMap<String, u64>, // capacities
        SimpleMap<String, u64>, // overdebts
        u128, // total deposited volume
        u128, // total borrowed volume
        SimpleMap<String, u128>, // deposited volumes
        SimpleMap<String, u128>, // borrowed volumes
    ) {
        let sum_capacity = 0;
        let sum_overdebt = 0;
        let capacities = simple_map::create<String, u64>();
        let overdebts = simple_map::create<String, u64>();
        let total_deposited_volume = 0;
        let total_borrowed_volume = 0;
        let deposited_volumes = simple_map::create<String, u128>();
        let borrowed_volumes = simple_map::create<String, u128>();

        let i = 0;
        while (i < vector::length(&keys)) {
            let key = vector::borrow(&keys, i);
            let (capacity, overdebt, deposited_volume, borrowed_volume) = capacity_and_overdebt_shadow(
                *key,
                *simple_map::borrow(&deposited_amounts, key),
                key<USDZ>(),
                *simple_map::borrow(&borrowed_amounts, key),
            );
            sum_capacity = sum_capacity + capacity;
            sum_overdebt = sum_overdebt + overdebt;
            simple_map::add(&mut capacities, *key, capacity);
            simple_map::add(&mut overdebts, *key, overdebt);
            total_deposited_volume = total_deposited_volume + deposited_volume;
            total_borrowed_volume = total_borrowed_volume + borrowed_volume;
            simple_map::add(&mut deposited_volumes, *key, deposited_volume);
            simple_map::add(&mut borrowed_volumes, *key, borrowed_volume);
            i = i + 1;
        };
        (sum_capacity, sum_overdebt, capacities, overdebts, total_deposited_volume, total_borrowed_volume, deposited_volumes, borrowed_volumes)
    }
    fun capacity_and_overdebt_shadow(
        deposited_key: String,
        deposited_amount: u64,
        borrowed_key: String,
        borrowed_amount: u64
    ): (
        u64, // amount as capacity (borrowable additionally)
        u64, // amount as overdebt (should repay)
        u128, // deposited_volume
        u128, // borrowed_volume
    ) {
        let deposited_volume = price_oracle::volume(&deposited_key, (deposited_amount as u128));
        let borrowed_volume = price_oracle::volume(&borrowed_key, (borrowed_amount as u128));
        let borrowable_volume = deposited_volume * (risk_factor::ltv_of(deposited_key) as u128) / risk_factor::precision_u128();
        if (borrowable_volume > borrowed_volume) {
            (
                (price_oracle::to_amount(&borrowed_key, borrowable_volume - borrowed_volume) as u64), // TODO: temp cast (maybe use u128 as return value)
                0,
                deposited_volume,
                borrowed_volume
            )
        } else if (borrowable_volume < borrowed_volume) {
            (
                0,
                (price_oracle::to_amount(&borrowed_key, (borrowed_volume - borrowable_volume)) as u64), // TODO: temp cast (maybe use u128 as return value)
                deposited_volume,
                borrowed_volume
            )
        } else {
            (
                0,
                0,
                deposited_volume,
                borrowed_volume
            )
        }
    }
    fun make_up_for_required_shadow_by_borrow(
        keys: vector<String>,
        required: u64,
        capacities: SimpleMap<String, u64>,
        borrowed_amounts: &mut SimpleMap<String, u64>,
        borrowed_volumes: &mut SimpleMap<String, u128>,
    ): SimpleMap<String, u64> {
        let borrowings = simple_map::create<String, u64>();
        let i = 0;
        let required_remains = required;
        while (i < vector::length(&keys)) {
            let key = vector::borrow(&keys, i);
            let capacity = simple_map::borrow(&capacities, key);
            if (*capacity > 0) {
                let borrowed_amount = simple_map::borrow_mut(borrowed_amounts, key);
                let borrowed_volume = simple_map::borrow_mut(borrowed_volumes, key);
                if (*capacity >= required_remains) {
                    *borrowed_amount = *borrowed_amount + required_remains;
                    simple_map::add(&mut borrowings, *key, required_remains);
                    let volume = price_oracle::volume(&key<USDZ>(), (required_remains as u128));
                    *borrowed_volume = *borrowed_volume + volume;
                    break
                } else {
                    *borrowed_amount = *borrowed_amount + *capacity;
                    simple_map::add(&mut borrowings, *key, *capacity);
                    required_remains = required_remains - *capacity;
                    let volume = price_oracle::volume(&key<USDZ>(), (*capacity as u128));
                    *borrowed_volume = *borrowed_volume + volume;
                };
            };
            i = i + 1;
        };
        borrowings
    }
    fun calc_to_optimize_shadow_by_borrow_and_repay_for_asset_to_shadow_pos(
        coins: vector<String>,
        optimized_hf: u64,
        deposited_volumes: SimpleMap<String, u128>,
        borrowed_volumes: SimpleMap<String, u128>
    ): (
        SimpleMap<String, u64>, // amounts to borrow
        SimpleMap<String, u64>, // amounts to repay
    ) {
        let i = 0;
        let usdz_key = key<USDZ>();
        let amount_to_borrow = simple_map::create<String, u64>();
        let amount_to_repay = simple_map::create<String, u64>();
        while (i < vector::length<String>(&coins)) {
            let key = vector::borrow(&coins, i);
            let deposited_volume = simple_map::borrow(&deposited_volumes, key);
            let borrowed_volume = simple_map::borrow(&borrowed_volumes, key);
            let current_hf = risk_factor::health_factor_of(
                *key,
                *deposited_volume,
                *borrowed_volume,
            ); // for AssetToShadow position
            // borrowed_volume + delta = (1 - optimized_hf) * (deposited_volume * LTV)
            let precision_u128 = risk_factor::precision_u128();
            let opt_borrow_volume = (precision_u128 - (optimized_hf as u128)) * (*deposited_volume) * (risk_factor::lt_of(*key) as u128) / precision_u128 / precision_u128;
            if (current_hf > optimized_hf) {
                simple_map::add(
                    &mut amount_to_borrow,
                    *key,
                    (price_oracle::to_amount(&usdz_key, opt_borrow_volume - *borrowed_volume) as u64) // TODO: temp cast (maybe use u128 as return value)
                );
            } else if (current_hf < optimized_hf) {
                simple_map::add(
                    &mut amount_to_repay,
                    *key,
                    (price_oracle::to_amount(&usdz_key, *borrowed_volume - opt_borrow_volume) as u64) // TODO: temp cast (maybe use u128 as return value)
                );
            };
            i = i + 1;
        };
        (amount_to_borrow, amount_to_repay)
    }

    fun execute_rebalance(
        account: &signer,
        coins: vector<String>,
        deposits: SimpleMap<String, u64>,
        withdraws: SimpleMap<String, u64>,
        borrows: SimpleMap<String, u64>,
        repays: SimpleMap<String, u64>,
        account_position_key: &AccountPositionKey,
        shadow_pool_key: &ShadowPoolKey,
    ) {
        let account_addr = signer::address_of(account);
        let i: u64;
        let length = vector::length(&coins);

        // prepare: check that whether existed deposited is conly or not
        let is_conly_vec = simple_map::create<String, bool>();
        i = 0;
        while (i < length) {
            let key = vector::borrow(&coins, i);
            let conly_deposited = account_position::conly_deposited_shadow_share_with(*key, account_addr);
            if (conly_deposited > 0) {
                simple_map::add(&mut is_conly_vec, *key, true);
            } else {
                // NOTE: default is also `normal_deposit`
                simple_map::add(&mut is_conly_vec, *key, false);
            };
            i = i + 1;
        };

        // borrow shadow
        if (simple_map::length(&borrows) > 0) {
            i = 0;
            while (i < length) {
                let key = vector::borrow(&coins, i);
                if (simple_map::contains_key(&borrows, key)) {
                    let amount = simple_map::borrow(&borrows, key);
                    let (_, share) = shadow_pool::borrow_for_with(*key, account_addr, account_addr, *amount, shadow_pool_key);
                    account_position::borrow_unsafe_with<Shadow>(*key, account_addr, share, account_position_key);
                };
                i = i + 1;
            };
        };

        // withdraw shadow
        if (simple_map::length(&withdraws) > 0) {
            i = 0;
            while (i < length) {
                let key = vector::borrow(&coins, i);
                if (simple_map::contains_key(&withdraws, key)) {
                    let amount = simple_map::borrow(&withdraws, key);
                    let is_conly = simple_map::borrow(&is_conly_vec, key);
                    let (_, share) = shadow_pool::withdraw_for_with(*key, account_addr, account_addr, *amount, *is_conly, 0, shadow_pool_key);
                    account_position::withdraw_unsafe_with<Shadow>(*key, account_addr, share, *is_conly, account_position_key);
                };
                i = i + 1;
            };
        };

        // repay shadow
        if (simple_map::length(&repays) > 0) {
            i = 0;
            while (i < length) {
                let key = vector::borrow(&coins, i);
                if (simple_map::contains_key(&repays, key)) {
                    let amount = simple_map::borrow(&repays, key);
                    let (_, share) = shadow_pool::repay_with(*key, account, *amount, shadow_pool_key);
                    account_position::repay_with<Shadow>(*key, account_addr, share, account_position_key);
                };
                i = i + 1;
            };
        };

        // deposit shadow
        if (simple_map::length(&deposits) > 0) {
            i = 0;
            while (i < length) {
                let key = vector::borrow(&coins, i);
                if (simple_map::contains_key(&deposits, key)) {
                    let amount = simple_map::borrow(&deposits, key);
                    
                    let balance = coin::balance<USDZ>(account_addr);
                    let amount_as_input = if (*amount > balance) balance else *amount; // TODO: check - short 1 amount because of rounded down somewhere

                    let is_conly = simple_map::borrow(&is_conly_vec, key);
                    let (_, share) = shadow_pool::deposit_for_with(*key, account, account_addr, amount_as_input, *is_conly, shadow_pool_key);
                    account_position::deposit_with<Shadow>(*key, account, account_addr, share, *is_conly, account_position_key);
                };
                i = i + 1;
            };
        };
    }
    fun borrowed_shares_to_amounts_for_shadow(keys: vector<String>, shares: vector<u64>): (
        vector<u64>, // amounts
        u64 // total amount // TODO: u128?
    ) {
        let i = 0;
        let amounts = vector::empty<u64>();
        let total_amount = 0;
        while (i < vector::length(&keys)) {
            let amount = shadow_pool::borrowed_share_to_amount(
                *vector::borrow<String>(&keys, i),
                *vector::borrow<u64>(&shares, i),
            );
            total_amount = total_amount + (amount as u64); // TODO: check type (u64?u128)
            vector::push_back(&mut amounts, (amount as u64)); // TODO: check type (u64?u128)
            i = i + 1;
        };
        (amounts, total_amount)
    }

    fun flatten_positions(
        liquidator_addr: address,
        target_addr: address, 
        account_position_key: &AccountPositionKey, 
        shadow_pool_key: &ShadowPoolKey
    ) acquires RebalanceEventHandle {
        let coins = vector::empty<String>();
        let deposited_volumes = vector::empty<u128>();
        let borrowed_volumes = vector::empty<u128>();

        // updated shadow volume
        let sum_rebalanced_deposited = 0;
        let sum_rebalanced_withdrawn = 0;
        let sum_rebalanced_borrowed = 0;
        let sum_rebalanced_repaid = 0;

        // for Quadratic Formula
        let sum_asset_deposited_mul_lt: u128 = 0;
        let sum_asset_borrowed: u128 = 0;
        let sum_shadow_deposited: u128 = 0;
        let sum_shadow_borrowed: u128 = 0;

        // Asset to Shadow: Collect amounts of the position
        let (all_coins_in_atos, _, balances_in_atos) = account_position::position<Asset>(target_addr);
        let unprotected_coins_in_atos = unprotected_coins(target_addr, all_coins_in_atos);
        let (deposited_amounts_atos, borrowed_amounts_atos) = shares_to_amounts_for_asset_to_shadow_pos(unprotected_coins_in_atos, balances_in_atos);        
        let i = vector::length(&unprotected_coins_in_atos);
        while (i > 0) {
            let key = vector::borrow<String>(&unprotected_coins_in_atos, i-1);
            let deposited_amount = *simple_map::borrow(&deposited_amounts_atos, key);
            let deposited_volume = price_oracle::volume(key, (deposited_amount as u128));
            vector::push_back<u128>(&mut deposited_volumes, (deposited_volume as u128));
            let borrowed_amount = *simple_map::borrow(&borrowed_amounts_atos, key);
            let borrowed_volume = price_oracle::volume(&key<USDZ>(), (borrowed_amount as u128));
            vector::push_back<u128>(&mut borrowed_volumes, (borrowed_volume as u128));
            vector::push_back<String>(&mut coins, *key);

            sum_asset_deposited_mul_lt = sum_asset_deposited_mul_lt + ((deposited_volume as u128) * (risk_factor::lt_of(*key) as u128));
            sum_shadow_borrowed = sum_shadow_borrowed + (borrowed_volume as u128);
            i = i - 1;
        };

        // Shadow to Asset: Collect amounts of the position
        let (all_coins_in_stoa, _, balances_in_stoa) = account_position::position<Shadow>(target_addr);
        let unprotected_coins_in_stoa = unprotected_coins(target_addr, all_coins_in_stoa);
        let (deposited_amounts_stoa, borrowed_amounts_stoa) = shares_to_amounts_for_shadow_to_asset_pos(unprotected_coins_in_stoa, balances_in_stoa);
        let i = vector::length(&unprotected_coins_in_stoa);
        while (i > 0) {
            let key = vector::borrow<String>(&unprotected_coins_in_stoa, i-1);
            let deposited_amount = *simple_map::borrow(&deposited_amounts_stoa, key);
            let deposited_volume = price_oracle::volume(&key<USDZ>(), (deposited_amount as u128));
            vector::push_back<u128>(&mut deposited_volumes, (deposited_volume as u128));
            let borrowed_amount = *simple_map::borrow(&borrowed_amounts_stoa, key);
            let borrowed_volume = price_oracle::volume(key, (borrowed_amount as u128));
            vector::push_back<u128>(&mut borrowed_volumes, (borrowed_volume as u128));
            vector::push_back<String>(&mut coins, key<USDZ>());
            
            sum_shadow_deposited = sum_shadow_deposited + (deposited_volume as u128);
            sum_asset_borrowed = sum_asset_borrowed + (borrowed_volume as u128);
            i = i - 1;
        };
   
        let optimized_hf = risk_factor::health_factor_weighted_average(
            coins,
            deposited_volumes,
            borrowed_volumes
        );

        // ax^2+bx-c=0
        let a = i128::from((risk_factor::lt_of_shadow() as u128) * sum_asset_deposited_mul_lt / (risk_factor::precision() as u128));
        let b = i128::mul(
            &i128::from((risk_factor::lt_of_shadow() as u128)),
            &i128::sub(
                &i128::from(sum_shadow_deposited),
                &i128::from(sum_shadow_borrowed)
            ),
        );
        let c = i128::neg_from((risk_factor::precision() as u128) * sum_asset_borrowed);

        if (vector::length(&unprotected_coins_in_atos) != 0 && vector::length(&unprotected_coins_in_stoa) != 0) {
            optimized_hf = (risk_factor::health_factor_with_quadratic_formula(a, b, c) as u64);
        };

        if (optimized_hf == 0) {
            // skip to flatten
            return
        };

        // Asset To Shadow: Prepare for Borrowing and Repaying Shadow
        let i = vector::length<String>(&unprotected_coins_in_atos);
        while (i > 0) {
            let key = vector::borrow(&unprotected_coins_in_atos, i-1);
            let deposited_amount = *simple_map::borrow(&deposited_amounts_atos, key);
            let deposited_volume = price_oracle::volume(key, (deposited_amount as u128));
            let borrowed_amount = *simple_map::borrow(&borrowed_amounts_atos, key);
            let borrowed_volume = price_oracle::volume(&key<USDZ>(), (borrowed_amount as u128));
            let current_hf = risk_factor::health_factor_of(*key, (deposited_volume as u128), (borrowed_volume as u128));
            let precision_u128 = (risk_factor::precision() as u128);
            let opt_borrow_volume = (deposited_volume as u128) * (risk_factor::lt_of(*key) as u128) / precision_u128 * (precision_u128 - (optimized_hf as u128)) / precision_u128;
            if (optimized_hf > current_hf) {
                // repay shadow
                let updated_volume = borrowed_volume - opt_borrow_volume;
                let (_, share) = shadow_pool::rebalance_for_repay(
                    *key,
                    target_addr,
                    (price_oracle::to_amount(&key<USDZ>(), (updated_volume)) as u64),
                    shadow_pool_key
                );
                account_position::repay_with<Shadow>(*key, target_addr, share, account_position_key);
                sum_rebalanced_repaid = sum_rebalanced_repaid + updated_volume;
            } else if (optimized_hf < current_hf) {
                // borrow shadow
                let updated_volume = opt_borrow_volume - borrowed_volume;
                let (_, share) = shadow_pool::rebalance_for_borrow(
                    *key,
                    target_addr,
                    (price_oracle::to_amount(&key<USDZ>(), updated_volume) as u64),
                    shadow_pool_key
                );
                account_position::borrow_unsafe_with<Shadow>(*key, target_addr, share, account_position_key);
                sum_rebalanced_borrowed = sum_rebalanced_borrowed + updated_volume;
            };
            i = i - 1;
        };
        
        // Shadow To Asset: Prepare for Depositing & Withdrawing Shadow
        let i = vector::length<String>(&unprotected_coins_in_stoa);
        while (i > 0) {
            let key = vector::borrow(&unprotected_coins_in_stoa, i-1);
            let deposited_amount = *simple_map::borrow(&deposited_amounts_stoa, key);
            let deposited_volume = price_oracle::volume(&key<USDZ>(), (deposited_amount as u128));
            let borrowed_amount = *simple_map::borrow(&borrowed_amounts_stoa, key);
            let borrowed_volume = price_oracle::volume(key, (borrowed_amount as u128));
            let current_hf = risk_factor::health_factor_of(key<USDZ>(), (deposited_volume as u128), (borrowed_volume as u128));
            let precision_u128 = (risk_factor::precision() as u128);
            let opt_deposit_volume = ((borrowed_volume as u128) * precision_u128 / (precision_u128 - (optimized_hf as u128))) * precision_u128 / (risk_factor::lt_of_shadow() as u128);
            if (current_hf > optimized_hf) {
                // withdraw shadow
                let updated_volume = deposited_volume - opt_deposit_volume;
                let (_,share) = shadow_pool::rebalance_for_withdraw(
                    *key,
                    target_addr,
                    (price_oracle::to_amount(&key<USDZ>(), updated_volume) as u64),
                    shadow_pool_key
                );
                account_position::withdraw_by_rebalance(*key, target_addr, share, account_position_key);
                sum_rebalanced_withdrawn = sum_rebalanced_withdrawn + updated_volume;
            } else if (current_hf < optimized_hf) {
                // deposit shadow
                let updated_volume = opt_deposit_volume - deposited_volume;
                let share = shadow_pool::rebalance_for_deposit(
                    *key,
                    target_addr,
                    (price_oracle::to_amount(&key<USDZ>(), updated_volume) as u64),
                    shadow_pool_key
                );
                account_position::deposit_by_rebalance(*key, target_addr, share, account_position_key);
                sum_rebalanced_deposited = sum_rebalanced_deposited + updated_volume;
            };
            i = i - 1;
        };

        event::emit_event<FlattenPositionsEvent>(
            &mut borrow_global_mut<RebalanceEventHandle>(permission::owner_address()).flatten_positions_event,
            FlattenPositionsEvent {
                caller: liquidator_addr,
                target: target_addr,
                health_factor: optimized_hf,
                sum_rebalanced_deposited,
                sum_rebalanced_withdrawn,
                sum_rebalanced_borrowed,
                sum_rebalanced_repaid,          },
        );

        // TODO: check the diff - if there is any diff ...
        // debug::print(&sum_rebalanced_deposited);
        // debug::print(&sum_rebalanced_withdrawed);
        // debug::print(&sum_rebalanced_borrowed);
        // debug::print(&sum_rebalanced_repaid);

        // should be equal
        // debug::print(&(sum_rebalanced_deposited + sum_rebalanced_repaid));
        // debug::print(&(sum_rebalanced_borrowed + sum_rebalanced_withdrawed));
    }

    #[test_only]
    use leizd_aptos_common::system_administrator;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self, USDC};
    #[test_only]
    use leizd::pool_manager;
    #[test_only]
    use leizd::test_initializer;
    #[test_only]
    fun initialize_for_test(owner: &signer): (AccountPositionKey, AssetPoolKey, ShadowPoolKey, OperatorKey) {
        account::create_account_for_test(signer::address_of(owner));
        test_initializer::initialize(owner);
        let account_position_key = account_position::initialize(owner);
        let asset_pool_key = asset_pool::initialize(owner);
        let shadow_pool_key = shadow_pool::initialize(owner);
        let rebalance_key = initialize(owner);
        (
            account_position_key,
            asset_pool_key,
            shadow_pool_key,
            rebalance_key,
        )
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 196611)]
    fun test_borrow_asset_with_rebalance_when_not_available_status(owner: &signer, account: &signer) acquires RebalanceEventHandle {
        let (account_position_key, asset_pool_key, shadow_pool_key, rebalance_key) = initialize_for_test(owner);
        pool_manager::initialize(owner);
        test_coin::init_usdc(owner);
        pool_manager::add_pool<USDC>(owner);

        system_administrator::disable_borrow_asset_with_rebalance<USDC>(owner);
        borrow_asset_with_rebalance<USDC>(account, 0, &account_position_key, &asset_pool_key, &shadow_pool_key, &rebalance_key);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 196611)]
    fun test_repay_shadow_evenly_when_not_available_status(owner: &signer, account: &signer) acquires RebalanceEventHandle {
        let (account_position_key, _, shadow_pool_key, rebalance_key) = initialize_for_test(owner);
        pool_manager::initialize(owner);

        system_administrator::disable_repay_shadow_evenly(owner);
        repay_shadow_evenly(account, 0, &account_position_key, &shadow_pool_key, &rebalance_key);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 196611)]
    fun test_liquidate_when_not_available_status(owner: &signer, account: &signer) acquires RebalanceEventHandle {
        let (account_position_key, asset_pool_key, shadow_pool_key, rebalance_key) = initialize_for_test(owner);
        pool_manager::initialize(owner);
        test_coin::init_usdc(owner);
        pool_manager::add_pool<USDC>(owner);

        system_administrator::disable_liquidate<USDC>(owner);
        liquidate<USDC, Asset>(account, signer::address_of(account), &account_position_key, &asset_pool_key, &shadow_pool_key, &rebalance_key);
    }
}
