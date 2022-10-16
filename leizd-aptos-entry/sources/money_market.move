/// The main entry point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd_aptos_entry::money_market {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map::{Self,SimpleMap};
    use aptos_framework::coin;
    use leizd_aptos_common::pool_type;
    use leizd_aptos_common::permission;
    use leizd_aptos_common::coin_key;
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool;
    use leizd_aptos_core::asset_pool::{Self, OperatorKey as AssetPoolKey};
    use leizd_aptos_core::shadow_pool::{Self, OperatorKey as ShadowPoolKey};
    use leizd_aptos_core::account_position::{Self, OperatorKey as AccountPositionKey};

    const EALREADY_INITIALIZED: u64 = 1;
    const ENO_SAFE_POSITION: u64 = 2;
    const ENO_DEPOSITED: u64 = 3;

    struct LendingPoolModKeys has key {
        account_position: AccountPositionKey,
        asset_pool: AssetPoolKey,
        shadow_pool: ShadowPoolKey,
    }

    public entry fun initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        assert!(!exists<LendingPoolModKeys>(owner_addr), error::invalid_argument(EALREADY_INITIALIZED));
        let account_position_key = account_position::initialize(owner);
        let asset_pool_key = asset_pool::initialize(owner);
        let shadow_pool_key = shadow_pool::initialize(owner);
        move_to(owner, LendingPoolModKeys {
            account_position: account_position_key,
            asset_pool: asset_pool_key,
            shadow_pool: shadow_pool_key
        });
    }

    fun keys(keys: &LendingPoolModKeys): (&AccountPositionKey, &AssetPoolKey, &ShadowPoolKey) {
        (&keys.account_position, &keys.asset_pool, &keys.shadow_pool)
    }

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a coin type e.g. WETH / WBTC
    /// P is a pool type and a user should select which pool to use: Asset or Shadow.
    /// e.g. Deposit USDZ for WETH Pool -> deposit<WETH,Asset>(x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit<WBTC,Shadow>(x,x,x)
    /// Note that a user cannot mix the both the collateral only position and the borrowable position for the same asset.
    public entry fun deposit<C,P>(
        account: &signer,
        amount: u64,
        is_collateral_only: bool,
    ) acquires LendingPoolModKeys {
        deposit_for<C,P>(account, signer::address_of(account), amount, is_collateral_only);
    }

    public entry fun deposit_for<C,P>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool,
    ) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        
        let user_share: u64;
        if (pool_type::is_type_asset<P>()) {
            (_, user_share) = asset_pool::deposit_for<C>(account, depositor_addr, amount, is_collateral_only, asset_pool_key);
        } else {
            (_, user_share) = shadow_pool::deposit_for<C>(account, depositor_addr, amount, is_collateral_only, shadow_pool_key);
        };
        account_position::deposit<C,P>(account, depositor_addr, user_share, is_collateral_only, account_position_key);
    }

    /// Withdraws an asset or a shadow from the pool.
    /// A user can withdraw an asset or a shadow position whether or not it is `is_collateral_only`.
    /// All amount will be withdrawn if the max u64 amount was set as the `amount`.
    public entry fun withdraw<C,P>(
        account: &signer,
        amount: u64,
    ) acquires LendingPoolModKeys {
        withdraw_for<C,P>(account, signer::address_of(account), amount);
    }

    public entry fun withdraw_for<C,P>(
        account: &signer,
        receiver_addr: address,
        amount: u64,
    ) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let depositor_addr = signer::address_of(account);
        let is_collateral_only = account_position::is_conly<C,P>(depositor_addr);
        let withdrawed_user_share: u64;
        if (pool_type::is_type_asset<P>()) {
            (_, withdrawed_user_share) = asset_pool::withdraw_for<C>(depositor_addr, receiver_addr, amount, is_collateral_only, asset_pool_key);
        } else {
            (_, withdrawed_user_share) = shadow_pool::withdraw_for<C>(depositor_addr, receiver_addr, amount, is_collateral_only, 0, shadow_pool_key);
        };
        account_position::withdraw<C,P>(depositor_addr, withdrawed_user_share, is_collateral_only, account_position_key);
    }

    public entry fun withdraw_all<C,P>(account: &signer) acquires LendingPoolModKeys {
        withdraw_all_for<C,P>(account, signer::address_of(account));
    }

    public entry fun withdraw_all_for<C,P>(
        account: &signer,
        receiver_addr: address,
    ) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let depositor_addr = signer::address_of(account);
        let is_collateral_only = account_position::is_conly<C,P>(depositor_addr);
        let user_share_all = account_position::withdraw_all<C,P>(depositor_addr, is_collateral_only, account_position_key);
        if (pool_type::is_type_asset<P>()) {
            asset_pool::withdraw_for_by_share<C>(depositor_addr, receiver_addr, user_share_all, is_collateral_only, asset_pool_key);
        } else {
            shadow_pool::withdraw_for_by_share<C>(depositor_addr, receiver_addr, user_share_all, is_collateral_only, 0, shadow_pool_key);
        };
    }

    /// Borrow an asset or a shadow from the pool.
    /// When a user executes `borrow` without the enough collateral, the result will be reverted.
    public entry fun borrow<C,P>(account: &signer, amount: u64) acquires LendingPoolModKeys {
        borrow_for<C,P>(account, signer::address_of(account), amount);
    }

    public entry fun borrow_for<C,P>(account: &signer, receiver_addr: address, amount: u64) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let borrower_addr = signer::address_of(account);
        let user_share: u64;
        if (pool_type::is_type_asset<P>()) {
            (_, user_share) = asset_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, asset_pool_key);
        } else {
            (_, user_share) = shadow_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, shadow_pool_key);
        };
        account_position::borrow<C,P>(account, borrower_addr, user_share, account_position_key);
    }

    /// Borrow the coin C with the shadow that is collected from the best pool.
    /// If there is enough shadow on the pool a user want to borrow, it would be
    /// the same action as the `borrow` function above.
    public entry fun borrow_asset_with_rebalance<C>(account: &signer, amount: u64) acquires LendingPoolModKeys {
        assert!(asset_pool::is_pool_initialized<C>() , 0);
        assert!(shadow_pool::is_initialized_asset<C>() , 0);

        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
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
        let (deposited_amounts, _, borrowed_amounts) = shares_to_amounts_for_shadow_to_asset_pos(unprotected_in_stoa, balances_in_stoa);
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
                coin_key::key<USDZ>(),
                total_deposited_volume_in_stoa,
                total_borrowed_volume_in_stoa
            );
            let (amounts_to_deposit, amounts_to_withdraw) = calc_to_optimize_shadow_by_rebalance_without_borrow(
                unprotected_in_stoa,
                optimized_hf,
                deposited_volumes_in_stoa,
                borrowed_volumes_in_stoa
            );
            execute_rebalance(
                account,
                unprotected_in_stoa,
                amounts_to_deposit,
                amounts_to_withdraw,
                simple_map::create<String, u64>(),
                simple_map::create<String, u64>(),
                account_position_key,
                shadow_pool_key
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
        let key_for_specified_asset = coin_key::key<C>();
        let (extra_for_borrowing_asset, insufficient_for_borrowing_asset, _, _) = extra_and_insufficient_shadow(
            coin_key::key<USDZ>(),
            *simple_map::borrow(&deposited_amounts, &key_for_specified_asset),
            key_for_specified_asset,
            *simple_map::borrow(&borrowed_amounts, &key_for_specified_asset),
        );
        // NOTE: use ltv because AssetToShadow position is controlled by borrow/repay (not deposit/withdraw)
        let numerator_of_required_shadow = ((insufficient_for_borrowing_asset - extra_for_borrowing_asset) as u128) * risk_factor::precision_u128();
        let required_shadow = ((numerator_of_required_shadow / (risk_factor::ltv_of_shadow() as u128)) as u64);

        let (coins_in_atos, _, balances_in_atos) = account_position::position<Asset>(account_addr);
        let unprotected_in_atos = unprotected_coins(account_addr, coins_in_atos);
        let (deposited_amounts_atos, borrowed_amounts_atos, _) = shares_to_amounts_for_asset_to_shadow_pos(unprotected_in_atos, balances_in_atos);
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
            let required_shadow_volume = price_oracle::volume(&coin_key::key<USDZ>(), (required_shadow as u128));
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
                    coin_key::key<USDZ>(),
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

            return ()
        };

        abort 0 // TODO error code
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
        u64, // total deposited amount // TODO: u128?
        SimpleMap<String, u64> // borrowed amounts
    ) {
        let i = 0;
        let deposited = simple_map::create<String, u64>();
        let total_deposited = 0;
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
                total_deposited = total_deposited + ((normal_deposited_amount + conly_deposited_amount) as u64); // TODO: check type (u64?u128?)
                simple_map::add(&mut deposited, *key, ((normal_deposited_amount + conly_deposited_amount) as u64)); // TODO: check type (u64?u128?)

                let borrowed_amount = asset_pool::borrowed_share_to_amount(
                    *key,
                    borrowed_share,
                );
                simple_map::add(&mut borrowed, *key, (borrowed_amount as u64)); // TODO: check type (u64?u128?)
            };
            i = i + 1;
        };
        (deposited, total_deposited, borrowed)
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
                coin_key::key<USDZ>(),
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
        let usdz_key = coin_key::key<USDZ>();
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
        u64, // total borrowed amount // TODO: u128?
    ) {
        let i = 0;
        let deposited = simple_map::create<String, u64>();
        let borrowed = simple_map::create<String, u64>();
        let total_borrowed = 0;
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
                total_borrowed = total_borrowed + (borrowed_amount as u64); // TODO: check type (u64?u128?)
                simple_map::add(&mut borrowed, *key, (borrowed_amount as u64)); // TODO: check type (u64?u128?)
            };
            i = i + 1;
        };
        (deposited, borrowed, total_borrowed)
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
                coin_key::key<USDZ>(),
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
        let borrowable_volume = deposited_volume * (risk_factor::ltv_of_shadow() as u128) / risk_factor::precision_u128();
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
                    let volume = price_oracle::volume(&coin_key::key<USDZ>(), (required_remains as u128));
                    *borrowed_volume = *borrowed_volume + volume;
                    break
                } else {
                    *borrowed_amount = *borrowed_amount + *capacity;
                    simple_map::add(&mut borrowings, *key, *capacity);
                    required_remains = required_remains - *capacity;
                    let volume = price_oracle::volume(&coin_key::key<USDZ>(), (*capacity as u128));
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
        let usdz_key = coin_key::key<USDZ>();
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
                    let (_ ,share) = shadow_pool::borrow_for_with(*key, account_addr, account_addr, *amount, shadow_pool_key);
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
                    let (_ ,share) = shadow_pool::withdraw_for_with(*key, account_addr, account_addr, *amount, *is_conly, 0, shadow_pool_key);
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
                    let (_ ,share) = shadow_pool::repay_with(*key, account, *amount, shadow_pool_key);
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
                    let (_ ,share) = shadow_pool::deposit_for_with(*key, account, account_addr, amount_as_input, *is_conly, shadow_pool_key);
                    account_position::deposit_with<Shadow>(*key, account, account_addr, share, *is_conly, account_position_key);
                };
                i = i + 1;
            };
        };
    }

    /// Repay an asset or a shadow from the pool.
    public entry fun repay<C,P>(account: &signer, amount: u64) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let repayer = signer::address_of(account);
        let repaid_user_share: u64;
        if (pool_type::is_type_asset<P>()) {
            (_, repaid_user_share) = asset_pool::repay<C>(account, amount, asset_pool_key);
        } else {
            (_, repaid_user_share) = shadow_pool::repay<C>(account, amount, shadow_pool_key);
        };
        account_position::repay<C,P>(repayer, repaid_user_share, account_position_key);
    }

    public entry fun repay_all<C,P>(account: &signer) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let repayer = signer::address_of(account);
        let user_share_all = account_position::repay_all<C,P>(repayer, account_position_key);
        if (pool_type::is_type_asset<P>()) {
            asset_pool::repay_by_share<C>(account, user_share_all, asset_pool_key);
        } else {
            shadow_pool::repay_by_share<C>(account, user_share_all, shadow_pool_key);
        };
    }

    /// repay_shadow_with_rebalance
    public entry fun repay_shadow_with_rebalance(account: &signer, amount: u64) acquires LendingPoolModKeys {
        let account_addr = signer::address_of(account);
        let (account_position_key, _, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

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

    /// Control available coin to rebalance
    public entry fun enable_to_rebalance<C>(account: &signer) {
        account_position::enable_to_rebalance<C>(account);
    }

    public entry fun disable_to_rebalance<C>(account: &signer) {
        account_position::disable_to_rebalance<C>(account);
    }

    //// Liquidation
    public entry fun liquidate<C,P>(account: &signer, target_addr: address) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let liquidator_addr = signer::address_of(account);
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        if (pool_type::is_type_asset<P>()) {
            // judge if the coin should be liquidated
            assert!(!account_position::is_safe_asset_to_shadow<C>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
    
            // TODO: rebalance by repaying shadow with left amount, that is from deposited as AssetToShadow

            // execute liquidation (repay + withdraw)
            let (deposited_amount, is_collateral_only) = account_position::deposited_asset_amount<C>(target_addr);
            let user_share_all = account_position::repay_all_for_liquidation<C,P>(target_addr, account_position_key);
            shadow_pool::repay_by_share<C>(account, user_share_all, shadow_pool_key);
            let (_, withdrawed_user_share) = asset_pool::withdraw_for_liquidation<C>(liquidator_addr, target_addr, deposited_amount, is_collateral_only, asset_pool_key);
            account_position::withdraw<C,P>(target_addr, withdrawed_user_share, is_collateral_only, account_position_key);
        } else {
            // judge if the coin should be liquidated
            assert!(!account_position::is_safe_shadow_to_asset<C>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
    
            // TODO: rebalance by depositing shadow (borrow shadow and rebalance it)
            // let (coins_in_stoa, _, balances_in_stoa) = account_position::position<Shadow>(target_addr);
            // let unprotected_in_stoa = unprotected_coins(target_addr, coins_in_stoa);
            // let (deposited_amounts, _, borrowed_amounts) = shares_to_amounts_for_shadow_to_asset_pos(unprotected_in_stoa, balances_in_stoa);
            // let (sum_extra, sum_insufficient, total_deposited_volume_in_stoa, total_borrowed_volume_in_stoa, deposited_volumes_in_stoa, borrowed_volumes_in_stoa) = sum_extra_and_insufficient_shadow(
            //     unprotected_in_stoa,
            //     deposited_amounts,
            //     borrowed_amounts,
            // );
            // if (sum_extra >= sum_insufficient) {
            //     // rebalance
            // };

            // execute liquidation (repay + withdraw)
            let (deposited_amount, is_collateral_only) = account_position::deposited_shadow_amount<C>(target_addr);
            let user_share_all = account_position::repay_all_for_liquidation<C,P>(target_addr, account_position_key);
            asset_pool::repay_by_share<C>(account, user_share_all, asset_pool_key);
            let (_, withdrawed_user_share) = shadow_pool::withdraw_for_liquidation<C>(liquidator_addr, target_addr, deposited_amount, is_collateral_only, shadow_pool_key);
            account_position::withdraw<C,P>(target_addr, withdrawed_user_share, is_collateral_only, account_position_key);
        };
    }

    /// Switch the deposited position.
    /// If a user want to switch the collateral to the collateral_only to protect it or vice versa
    /// without the liquidation risk, the user should call this function.
    /// `to_collateral_only` should be true if the user wants to switch it to the collateral_only.
    /// `to_collateral_only` should be false if the user wants to switch it to the borrowable collateral.
    public entry fun switch_collateral<C,P>(account: &signer, to_collateral_only: bool) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let account_addr = signer::address_of(account);
        let key = coin_key::key<C>();
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        let to_share: u64;
        if (pool_type::is_type_asset<P>()) {
            account_position::assert_invalid_deposit_asset(key, account_addr, !to_collateral_only);
            let all_user_share = if (to_collateral_only) account_position::deposited_asset_share<C>(account_addr) else account_position::conly_deposited_asset_share<C>(account_addr);
            (_, _, to_share) = asset_pool::switch_collateral<C>(account_addr, all_user_share, to_collateral_only, asset_pool_key);
        } else {
            account_position::assert_invalid_deposit_shadow(key, account_addr, !to_collateral_only);
            let all_user_share = if (to_collateral_only) account_position::deposited_shadow_share<C>(account_addr) else account_position::conly_deposited_shadow_share<C>(account_addr);
            (_, _, to_share) = shadow_pool::switch_collateral<C>(account_addr, all_user_share, to_collateral_only, shadow_pool_key);
        };
        account_position::switch_collateral<C,P>(account_addr, to_collateral_only, to_share, account_position_key);
    }

    /// central liquidity pool
    public entry fun deposit_to_central_liquidity_pool(account: &signer, amount: u64) {
        central_liquidity_pool::deposit(account, amount);
    }

    public entry fun withdraw_from_central_liquidity_pool(account: &signer, amount: u64) {
        central_liquidity_pool::withdraw(account, amount);
    }

    // harvest protocol share fee
    public entry fun harvest_protocol_fees<C>() {
        shadow_pool::harvest_protocol_fees<C>();
        asset_pool::harvest_protocol_fees<C>();
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_lib::math128;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self, USDC, USDT, WETH, UNI};
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd_aptos_treasury::treasury;
    #[test_only]
    use leizd_aptos_core::test_initializer;
    #[test_only]
    use leizd_aptos_core::interest_rate;
    #[test_only]
    use leizd_aptos_core::pool_manager;
    #[test_only]
    use leizd_aptos_core::initializer;
    #[test_only]
    public entry fun borrow_unsafe_for_test<C,P>(account: &signer, amount: u64) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();
        let (_, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let borrower_addr = signer::address_of(account);
        let receiver_addr = signer::address_of(account);
        let user_share: u64;
        if (pool_type::is_type_asset<P>()) {
            (_, user_share) = asset_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, asset_pool_key);
        } else {
            (_, user_share) = shadow_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, shadow_pool_key);
        };
        account_position::borrow_unsafe_for_test<C,P>(borrower_addr, user_share);
    }
    #[test(owner=@leizd)]
    fun test_initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        assert!(exists<LendingPoolModKeys>(owner_addr), 0);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_twice(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize(owner);
    }
    #[test_only]
    fun initialize_lending_pool_for_test(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1648738800 * 1000 * 1000); // 20220401T00:00:00

        account::create_account_for_test(signer::address_of(owner));

        // initialize
        initializer::initialize(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner); // TODO: clean
        initialize(owner);

        // add_pool
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        pool_manager::add_pool<USDC>(owner);
        pool_manager::add_pool<USDT>(owner);
        pool_manager::add_pool<WETH>(owner);
        pool_manager::add_pool<UNI>(owner);
    }
    #[test_only]
    fun setup_account_for_test(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);
    }
    #[test_only]
    fun setup_liquidity_provider_for_test(owner: &signer, account: &signer) {
        setup_account_for_test(account);

        let account_addr = signer::address_of(account);
        managed_coin::mint<USDC>(owner, account_addr, 999999);
        managed_coin::mint<USDT>(owner, account_addr, 999999);
        managed_coin::mint<WETH>(owner, account_addr, 999999);
        managed_coin::mint<UNI>(owner, account_addr, 999999);
        usdz::mint_for_test(account_addr, 9999999);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit<WETH, Asset>(account, 100, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        deposit<WETH, Shadow>(account, 100, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 100, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 100, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_deposit_for_with_asset(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        setup_account_for_test(for);
        account_position::initialize_position_if_necessary_for_test(for); // NOTE: fail deposit_for if Position resource is initialized

        let for_addr = signer::address_of(for);
        deposit_for<WETH, Asset>(account, for_addr, 100, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100, 0);
        assert!(account_position::deposited_asset_share<WETH>(for_addr) == 100, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_deposit_for_with_shadow(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        setup_account_for_test(for);
        account_position::initialize_position_if_necessary_for_test(for); // NOTE: fail deposit_for if Position resource is initialized

        let for_addr = signer::address_of(for);
        deposit_for<WETH, Shadow>(account, for_addr, 100, false);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 100, 0);
        assert!(account_position::deposited_shadow_share<WETH>(for_addr) == 100, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit<WETH, Asset>(account, 100, false);
        withdraw<WETH, Asset>(account, 75);

        assert!(coin::balance<WETH>(account_addr) == 75, 0);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 25, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        deposit<WETH, Shadow>(account, 100, false);
        withdraw<WETH, Shadow>(account, 75);

        assert!(coin::balance<USDZ>(account_addr) == 75, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 25, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_withdraw_for_with_asset(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        setup_account_for_test(for);

        deposit<WETH, Asset>(account, 100, false);
        let for_addr = signer::address_of(for);
        withdraw_for<WETH, Asset>(account, for_addr, 75);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(for_addr) == 75, 0);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 25, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_withdraw_for_with_shadow(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        setup_account_for_test(for);

        deposit<WETH, Shadow>(account, 100, false);
        let for_addr = signer::address_of(for);
        withdraw_for<WETH, Shadow>(account, for_addr, 75);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(for_addr) == 75, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 25, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_all_with_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 10000);

        deposit<WETH, Asset>(account, 1000, false);
        deposit<WETH, Asset>(account, 200, false);
        deposit<WETH, Asset>(account, 30, false);
        assert!(coin::balance<WETH>(account_addr) == 10000 - 1230, 0);

        withdraw_all<WETH, Asset>(account);
        assert!(coin::balance<WETH>(account_addr) == 10000, 0);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_all_with_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100000);

        deposit<WETH, Shadow>(account, 50000, false);
        deposit<WETH, Shadow>(account, 4000, false);
        deposit<WETH, Shadow>(account, 300, false);
        assert!(coin::balance<USDZ>(account_addr) == 100000 - 54300, 0);

        withdraw_all<WETH, Shadow>(account);
        assert!(coin::balance<USDZ>(account_addr) == 100000, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }

    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_shadow_from_asset(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        // prerequisite
        deposit<WETH, Shadow>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(account, 100, false);
        borrow<WETH, Shadow>(account, 68);

        assert!(coin::balance<USDZ>(account_addr) == 68, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 69, 0); // NOTE: amount + fee
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 69, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_asset_from_shadow(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        // prerequisite
        deposit<WETH, Asset>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 100, false);
        borrow<WETH, Asset>(account, 88);

        assert!(coin::balance<WETH>(account_addr) == 88, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 89, 0); // NOTE: amount + fee
        assert!(account_position::borrowed_asset_share<WETH>(account_addr) == 89, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,for=@0x333,aptos_framework=@aptos_framework)]
    fun test_borrow_for_with_shadow_from_asset(owner: &signer, lp: &signer, account: &signer, for: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        setup_account_for_test(for);

        // prerequisite
        deposit<WETH, Shadow>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(account, 100, false);
        let for_addr = signer::address_of(for);
        borrow_for<WETH, Shadow>(account, for_addr, 68);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(for_addr) == 68, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 69, 0); // NOTE: amount + fee
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 69, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(for_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,for=@0x333,aptos_framework=@aptos_framework)]
    fun test_borrow_for_with_asset_from_shadow(owner: &signer, lp: &signer, account: &signer, for: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        setup_account_for_test(for);

        // prerequisite
        deposit<WETH, Asset>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 100, false);
        let for_addr = signer::address_of(for);
        borrow_for<WETH, Asset>(account, for_addr, 88);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(for_addr) == 88, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 89, 0); // NOTE: amount + fee
        assert!(account_position::borrowed_asset_share<WETH>(account_addr) == 89, 0);
        assert!(account_position::borrowed_asset_share<WETH>(for_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_with_shadow(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        // prerequisite
        deposit<WETH, Shadow>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(account, 100, false);
        borrow<WETH, Shadow>(account, 68);
        repay<WETH, Shadow>(account, 49);

        assert!(coin::balance<USDZ>(account_addr) == 19, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 20, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 20, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_with_asset(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        // prerequisite
        deposit<WETH, Asset>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 100, false);
        borrow<WETH, Asset>(account, 88);
        repay<WETH, Asset>(account, 49);

        assert!(coin::balance<WETH>(account_addr) == 39, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 40, 0);
        assert!(account_position::borrowed_asset_share<WETH>(account_addr) == 40, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_all_with_shadow(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 200000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 100500, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(account, 200000, false);
        borrow<WETH, Shadow>(account, 100000);
        usdz::mint_for_test(account_addr, 500);
        repay_all<WETH, Shadow>(account);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_all_with_asset(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 200000);

        // prerequisite
        deposit<WETH, Asset>(lp, 100500, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 200000, false);
        borrow<WETH, Asset>(account, 100000);
        managed_coin::mint<WETH>(owner, account_addr, 500);
        repay_all<WETH, Asset>(account);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::borrowed_asset_share<WETH>(account_addr) == 0, 0);
    }
    #[test_only]
    fun prepare_to_exec_repay_shadow_with_rebalance(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<USDC>(owner, account_addr, 200000);
        managed_coin::mint<USDT>(owner, account_addr, 200000);
        managed_coin::mint<WETH>(owner, account_addr, 200000);
        managed_coin::mint<UNI>(owner, account_addr, 200000);

        // prerequisite
        deposit<USDC, Shadow>(lp, 200000, false);
        deposit<USDT, Shadow>(lp, 200000, false);
        deposit<WETH, Shadow>(lp, 200000, false);
        deposit<UNI, Shadow>(lp, 200000, false);

        // execute
        deposit<USDC, Asset>(account, 200000, false);
        deposit<USDT, Asset>(account, 200000, false);
        deposit<WETH, Asset>(account, 200000, false);
        deposit<UNI, Asset>(account, 200000, false);
        borrow<USDC, Shadow>(account, 20000);
        borrow<USDT, Shadow>(account, 40000);
        borrow<WETH, Shadow>(account, 60000);
        borrow<UNI, Shadow>(account, 80000);
        assert!(shadow_pool::borrowed_amount<USDC>() == 20100, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20100, 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == 40200, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 40200, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 60300, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 60300, 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == 80400, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == 80400, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_shadow_with_rebalance_to_repay_all(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_repay_shadow_with_rebalance(owner, lp, account, aptos_framework);
        let account_addr = signer::address_of(account);

        usdz::mint_for_test(account_addr, 1000);
        repay_shadow_with_rebalance(account, 201000);
        assert!(shadow_pool::borrowed_amount<USDC>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_shadow_with_rebalance_to_repay_all_in_part(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_repay_shadow_with_rebalance(owner, lp, account, aptos_framework);
        let account_addr = signer::address_of(account);

        repay_shadow_with_rebalance(account, 40201 * 4);
        assert!(shadow_pool::borrowed_amount<USDC>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 20099, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 20099, 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == 40199, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == 40199, 0);
        assert!(coin::balance<USDZ>(account_addr) == 200000 - (40201 * 4) + (40201 - 20100) + (40201 - 40200), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_repay_shadow_with_rebalance_to_repay_evenly(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_repay_shadow_with_rebalance(owner, lp, account, aptos_framework);
        let account_addr = signer::address_of(account);

        repay_shadow_with_rebalance(account, 20000 * 4);
        assert!(shadow_pool::borrowed_amount<USDC>() == 100, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 100, 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == 20200, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 20200, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 40300, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40300, 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == 60400, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == 60400, 0);
        assert!(coin::balance<USDZ>(account_addr) == 200000 - (20000 * 4), 0);
    }

    #[test(owner=@leizd_aptos_entry,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_enable_to_rebalance_and_disable_to_rebalance(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);

        // prerequisite: create position by depositing some asset
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);
        deposit<WETH, Shadow>(account, 100, false);

        // execute
        assert!(!account_position::is_protected<WETH>(account_addr), 0);
        disable_to_rebalance<WETH>(account);
        assert!(account_position::is_protected<WETH>(account_addr), 0);
        enable_to_rebalance<WETH>(account);
        assert!(!account_position::is_protected<WETH>(account_addr), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,target=@0x444,aptos_framework=@aptos_framework)]
    fun test_liquidate_asset(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, target: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(target);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        managed_coin::mint<WETH>(owner, borrower_addr, 2000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 2000, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(borrower, 2000, false);
        borrow<WETH, Shadow>(borrower, 1000);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 2000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 1000 + 5, 0);
        assert!(account_position::deposited_asset_share<WETH>(borrower_addr) == 2000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(borrower_addr) == 1005, 0);
        assert!(coin::balance<WETH>(borrower_addr) == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000 ,0);
        assert!(coin::balance<WETH>(liquidator_addr) == 0, 0);
        assert!(treasury::balance<WETH>() == 0, 0);

        risk_factor::update_config<WETH>(owner, risk_factor::precision() / 100 * 10, risk_factor::precision() / 100 * 10); // 10%

        usdz::mint_for_test(liquidator_addr, 1005);
        liquidate<WETH, Asset>(liquidator, borrower_addr);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_asset_share<WETH>(borrower_addr) == 0, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(borrower_addr) == 0, 0);
        assert!(coin::balance<WETH>(borrower_addr) == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000 ,0);
        assert!(coin::balance<WETH>(liquidator_addr) == 1990, 0);
        assert!(treasury::balance<WETH>() == 10, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,target=@0x444,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_liquidate_asset_with_insufficient_amount(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, target: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(target);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        managed_coin::mint<WETH>(owner, borrower_addr, 2000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 2000, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(borrower, 2000, false);
        borrow<WETH, Shadow>(borrower, 1000);

        risk_factor::update_config<WETH>(owner, risk_factor::precision() / 100 * 10, risk_factor::precision() / 100 * 10); // 10%

        usdz::mint_for_test(liquidator_addr, 1004);
        liquidate<WETH, Asset>(liquidator, borrower_addr);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,target=@0x444,aptos_framework=@aptos_framework)]
    fun test_liquidate_shadow(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, target: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(target);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        usdz::mint_for_test(borrower_addr, 2000);

        // prerequisite
        deposit<WETH, Asset>(lp, 2000, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(borrower, 2000, false);
        borrow<WETH, Asset>(borrower, 1000);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 2000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 1000 + 5, 0);
        assert!(account_position::deposited_shadow_share<WETH>(borrower_addr) == 2000, 0);
        assert!(account_position::borrowed_asset_share<WETH>(borrower_addr) == 1005, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
        assert!(coin::balance<WETH>(borrower_addr) == 1000, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);
        assert!(treasury::balance<USDZ>() == 0, 0);

        risk_factor::update_config<USDZ>(owner, risk_factor::precision() / 100 * 10, risk_factor::precision() / 100 * 10); // 10%

        managed_coin::mint<WETH>(owner, liquidator_addr, 1005);
        liquidate<WETH, Shadow>(liquidator, borrower_addr);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_shadow_share<WETH>(borrower_addr) == 0, 0);
        assert!(account_position::borrowed_asset_share<WETH>(borrower_addr) == 0, 0);
        assert!(coin::balance<WETH>(borrower_addr) == 1000, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);
        assert!(treasury::balance<WETH>() == 5, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,target=@0x444,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_liquidate_shadow_insufficient_amount(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, target: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(target);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        usdz::mint_for_test(borrower_addr, 2000);

        // prerequisite
        deposit<WETH, Asset>(lp, 2000, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(borrower, 2000, false);
        borrow<WETH, Asset>(borrower, 1000);

        risk_factor::update_config<USDZ>(owner, risk_factor::precision() / 100 * 10, risk_factor::precision() / 100 * 10); // 10%

        managed_coin::mint<WETH>(owner, liquidator_addr, 1004);
        liquidate<WETH, Shadow>(liquidator, borrower_addr);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_switch_collateral_to_collateral_only(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000);

        // prerequisite
        deposit<WETH, Asset>(account, 1000, false);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 1000, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 1000, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account_addr) == 0, 0);

        // execute
        switch_collateral<WETH, Asset>(account, true);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 1000, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account_addr) == 1000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_switch_collateral_to_normal(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 1000);

        // prerequisite
        deposit<WETH, Shadow>(account, 1000, true);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 0, 0);
        assert!(shadow_pool::conly_deposited_amount<WETH>() == 1000, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 1000, 0);

        // execute
        switch_collateral<WETH, Shadow>(account, false);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 1000, 0);
        assert!(shadow_pool::conly_deposited_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 1000, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_switch_collateral_for_checking_share(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 50000);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        deposit<WETH, Asset>(lp, 150000, false);
        deposit<WETH, Shadow>(lp, 150000, false);
        borrow<WETH, Asset>(lp, 40000);
        deposit<WETH, Asset>(account, 50000, false);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 200000, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_normal_deposited_share<WETH>() == 200000, 0);
        assert!(asset_pool::total_conly_deposited_share<WETH>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 40000, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account_addr) == 0, 0);

        // execute: normal -> collateral only
        asset_pool::earn_interest_without_using_interest_rate_module_for_test<WETH>(
            (interest_rate::precision() as u128) // 100%
        );
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 200000 + 40000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 40000 + 40000, 0);

        switch_collateral<WETH, Asset>(account, true);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == (200000 + 40000) - (50000 + 10000), 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == (50000 + 10000), 0);
        assert!(asset_pool::total_normal_deposited_share<WETH>() == 150000, 0);
        assert!(asset_pool::total_conly_deposited_share<WETH>() == 60000, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account_addr) == 60000, 0);

        // execute: collateral only -> normal
        asset_pool::earn_interest_without_using_interest_rate_module_for_test<WETH>(
            ((interest_rate::precision() / 1000 * 750) as u128) // 75%
        );
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 180000 + 60000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 80000 + 60000, 0);

        switch_collateral<WETH, Asset>(account, false);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 240000 + 60000, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_normal_deposited_share<WETH>() == 150000 + (60000 * 150000 / 240000), 0);
        assert!(asset_pool::total_conly_deposited_share<WETH>() == 0, 0);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 60000 * 150000 / 240000, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account_addr) == 0, 0);
    }

    // scenario
    #[test(owner=@leizd_aptos_entry,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_scenario__deposit_and_borrow_with_larger_numbers(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(depositor);
        setup_account_for_test(borrower);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        let billion = math64::pow(10, 9);
        usdz::mint_for_test(depositor_addr, 500 * billion * math64::pow(10, 6)); // 500k USDZ TODO: decimal scale by oracle price
        managed_coin::mint<USDC>(owner, borrower_addr, 500 * billion * math64::pow(10, 6)); // 500k USDC
        managed_coin::mint<USDT>(owner, depositor_addr, 500 * billion * math64::pow(10, 6)); // 500k USDT

        deposit<USDC, Shadow>(depositor, 500 * billion * math64::pow(10, 6), false);
        deposit<USDT, Asset>(depositor, 500 * billion * math64::pow(10, 6), false);

        deposit<USDC, Asset>(borrower, 500 * billion * math64::pow(10, 6), false);
        borrow<USDC, Shadow>(borrower, 300 * billion * math64::pow(10, 6));
        deposit<USDT, Shadow>(borrower, 200 * billion * math64::pow(10, 6), false);
        borrow<USDT, Asset>(borrower, 100 * billion * math64::pow(10, 6));

        assert!(coin::balance<USDC>(borrower_addr) == 0, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 500 * (billion as u128) * math128::pow(10, 6), 0);
        assert!(account_position::deposited_asset_share<USDC>(borrower_addr) == 500 * billion * math64::pow(10, 6), 0);
        assert!(account_position::borrowed_asset_share<USDT>(borrower_addr) == 1005 * billion / 10 * math64::pow(10, 6), 0); // +0.5% entry fee
    }
    #[test(owner=@leizd_aptos_entry,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_scenario__borrow_asset_with_rebalance_with_larger_numbers(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(depositor);
        setup_account_for_test(borrower);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        let billion = math64::pow(10, 9);
        usdz::mint_for_test(depositor_addr, 500 * billion * math64::pow(10, 6)); // 500b USDZ TODO: decimal scale by oracle price
        managed_coin::mint<USDC>(owner, borrower_addr, 500 * billion * math64::pow(10, 6)); // 500b USDC
        managed_coin::mint<USDT>(owner, depositor_addr, 500 * billion * math64::pow(10, 6)); // 500b USDT

        deposit<USDC, Shadow>(depositor, 300 * billion * math64::pow(10, 6), false);
        deposit<USDT, Shadow>(depositor, 200 * billion * math64::pow(10, 6), false);
        deposit<USDT, Asset>(depositor, 500 * billion * math64::pow(10, 6), false);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        deposit<USDC, Asset>(borrower, 500 * billion * math64::pow(10, 6), false);
        assert!(account_position::borrowed_shadow_share<USDC>(borrower_addr) == 0, 0);
        assert!(account_position::deposited_shadow_share<USDT>(borrower_addr) == 0, 0);
        assert!(account_position::borrowed_asset_share<USDT>(borrower_addr) == 0, 0);
        borrow_asset_with_rebalance<USDT>(borrower, 180 * billion * math64::pow(10, 6));

        assert!(coin::balance<USDC>(borrower_addr) == 0, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 500 * (billion as u128) * math128::pow(10, 6), 0);
        assert!(account_position::deposited_asset_share<USDC>(borrower_addr) == 500 * billion * math64::pow(10, 6), 0);
        assert!(account_position::borrowed_shadow_share<USDC>(borrower_addr) == 200 * billion * math64::pow(10, 6), 0);
        assert!(account_position::deposited_shadow_share<USDT>(borrower_addr) == 200 * billion * math64::pow(10, 6), 0);
        assert!(account_position::borrowed_asset_share<USDT>(borrower_addr) == 180 * billion * math64::pow(10, 6), 0);
    }

    // borrow_asset_with_rebalance
    #[test_only]
    fun prepare_to_exec_borrow_asset_with_rebalance(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);

        // prerequisite
        deposit<USDC, Asset>(lp, 500000, false);
        deposit<USDT, Asset>(lp, 500000, false);
        deposit<WETH, Asset>(lp, 500000, false);
        deposit<UNI, Asset>(lp, 500000, false);
        deposit<USDC, Shadow>(lp, 500000, false);
        deposit<USDT, Shadow>(lp, 500000, false);
        deposit<WETH, Shadow>(lp, 500000, false);
        deposit<UNI, Shadow>(lp, 500000, false);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_1(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 100000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Shadow>(account, 100000, false);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(asset_pool::normal_deposited_share_to_amount(
            coin_key::key<WETH>(),
            account_position::deposited_asset_share<WETH>(account_addr)
        ) == 100000, 0);
        assert!(shadow_pool::normal_deposited_share_to_amount(
            coin_key::key<USDC>(),
            account_position::deposited_shadow_share<USDC>(account_addr)
        ) == 0, 0);
        assert!(shadow_pool::normal_deposited_share_to_amount(
            coin_key::key<UNI>(),
            account_position::deposited_shadow_share<UNI>(account_addr)
        ) == 100000, 0);

        assert!(asset_pool::borrowed_share_to_amount(
            coin_key::key<UNI>(),
            account_position::borrowed_asset_share<UNI>(account_addr)
        ) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_2(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 100000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 50000);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 83332, 0); // -> 83333 ?
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 16666, 0); // -> 16667 ?
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 2, 0); // -> 0, TODO: check
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_3(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 50000 - 10000 + 100000 + 10000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<WETH, Shadow>(account, 50000, false);
        borrow<WETH, Shadow>(account, 10000);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 50000);
        deposit<UNI, Shadow>(account, 10000, false);

        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 133332, 0); // -> 133333 ?
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 26666, 0); // -> 26667 ?
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 2, 0); // -> 0, TODO: check
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_4(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 50000 - 10000 + 100000 + 10000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<WETH, Shadow>(account, 50000, false);
        borrow<WETH, Shadow>(account, 10000);
        disable_to_rebalance<WETH>(account);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 50000);
        deposit<UNI, Shadow>(account, 10000, false);

        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 91666, 0); // -> 91667
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 18332, 0); // -> 18333
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 2, 0); // -> 0, TODO: check
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_5__adjust_three_with_normal_only(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 100000, false);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 100000, false);
        borrow<USDT, Asset>(account, 70000);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 100000, 0);
        assert!(coin::balance<WETH>(account_addr) == 20000, 0);
        assert!(coin::balance<USDC>(account_addr) == 45000, 0);
        assert!(coin::balance<USDT>(account_addr) == 70000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 140000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_5__adjust_three_with_conly_only(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 100000, true);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 100000, true);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 100000, true);
        borrow<USDT, Asset>(account, 70000);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 100000, 0);
        assert!(coin::balance<WETH>(account_addr) == 20000, 0);
        assert!(coin::balance<USDC>(account_addr) == 45000, 0);
        assert!(coin::balance<USDT>(account_addr) == 70000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 140000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_5__adjust_three_with_normal_and_conly(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 100000, true);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 100000, true);
        borrow<USDT, Asset>(account, 70000);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 100000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 140000, 0);

        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_6(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 150000, true);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 95000, false);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 45000, true);
        borrow_unsafe_for_test<USDT, Asset>(account, 70000);
        deposit<UNI, Shadow>(account, 10000, false);
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 150000, 0);
        assert!(account_position::borrowed_asset_share<WETH>(account_addr) == 20000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 95000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 45000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 45000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 70000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(account_position::conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 140000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);

        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        //// for pool
        let liquidity_from_lp = 500000;
        assert!(shadow_pool::normal_deposited_amount<WETH>() - liquidity_from_lp == 0, 0);
        assert!(shadow_pool::conly_deposited_amount<WETH>() == 40000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 20000, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() - liquidity_from_lp == 90000, 0);
        assert!(shadow_pool::conly_deposited_amount<USDC>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 45000, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() - liquidity_from_lp == 0, 0);
        assert!(shadow_pool::conly_deposited_amount<USDT>() == 140000, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 70000, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() - liquidity_from_lp == 30000, 0);
        assert!(shadow_pool::conly_deposited_amount<UNI>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<UNI>() == 15000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_1(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        deposit<WETH, Asset>(account, 100000, false);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 11111, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 11110, 0); // -> 11111, TODO: check (rounded or truncated somewhere)
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 1, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_2(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Asset>(account, 50000, false);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 7407, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 3703, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 11110, 0); // -> 11111, TODO: check (rounded or truncated somewhere)
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_2_with_fee(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Asset>(account, 50000, false);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 7499, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 3740, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 11164, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_3(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        // usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 9000);
        deposit<USDC, Asset>(account, 50000, false);
        // deposit<USDT, Shadow>(account, 50000, false);
        // borrow<USDT, Asset>(account, 47500);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 9000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        // assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        // assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 47500, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        // assert!(coin::balance<USDT>(account_addr) == 47500, 0);
        assert!(coin::balance<USDZ>(account_addr) == 9000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 13407, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 6703, 0); // -> 6704 ?
        // assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 0, 0);
        // assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 11110, 0); // -> 11111 ?
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        // assert!(coin::balance<USDT>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 9000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_4(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow_unsafe_for_test<USDT, Asset>(account, 45000);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 45000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 45000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40740, 0); // -> 40741
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20370, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 49998, 0); // -> 50000
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 45000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 11110, 0); // -> 11111
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 45000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50002, 0); // -> 50000
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_5(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow<USDT, Asset>(account, 40000);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40740, 0); // -> 40741
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20370, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 48888, 0); // -> 48889
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 12222, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);

        //// for pool
        let liquidity_from_lp = 500000;
        ////// AssetToShadow
        assert!(asset_pool::total_normal_deposited_amount<WETH>() - liquidity_from_lp == 100000, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 40740, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() - liquidity_from_lp == 50000, 0);
        assert!(asset_pool::total_conly_deposited_amount<USDC>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 20370, 0);
        ////// ShadowToAsset
        assert!(shadow_pool::normal_deposited_amount<USDT>() - liquidity_from_lp == 48888, 0);
        assert!(shadow_pool::conly_deposited_amount<USDT>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 40000, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() - liquidity_from_lp == 12222, 0);
        assert!(shadow_pool::conly_deposited_amount<UNI>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<UNI>() == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_6(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow<USDT, Asset>(account, 40000);
        disable_to_rebalance<WETH>(account);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 11111, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 48888, 0); // -> 48889
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 12222, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50001, 0); // -> 50000
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_7(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow_unsafe_for_test<USDT, Asset>(account, 50000);
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 50000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40740, 0); // -> 40741
        assert!(account_position::deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20370, 0);
        assert!(account_position::deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::deposited_shadow_share<UNI>(account_addr) == 11111, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 49999, 0); // -> 50000
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
}
