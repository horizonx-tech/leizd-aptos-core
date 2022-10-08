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
    use leizd_aptos_common::pool_type;
    use leizd_aptos_common::permission;
    use leizd_aptos_logic::rebalance::{Self,Rebalance};
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool;
    use leizd_aptos_core::asset_pool::{Self, OperatorKey as AssetPoolKey};
    use leizd_aptos_core::shadow_pool::{Self, OperatorKey as ShadowPoolKey};
    use leizd_aptos_core::account_position::{Self, OperatorKey as AccountPositionKey};

    const EALREADY_INITIALIZED: u64 = 1;

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
        borrow_asset_for_with_rebalance<C>(account, signer::address_of(account), amount);
    }

    public entry fun borrow_asset_for_with_rebalance<C>(account: &signer, receiver_addr: address, amount: u64) acquires LendingPoolModKeys {
        let borrower_addr = signer::address_of(account);
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        let (deposits, withdraws, borrows, repays) = account_position::borrow_asset_with_rebalance<C>(borrower_addr, amount, account_position_key);

        // borrow shadow
        let i = vector::length<Rebalance>(&borrows);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&borrows, i-1);
            shadow_pool::borrow_for_with(rebalance::key(rebalance), borrower_addr, borrower_addr, rebalance::amount(rebalance), shadow_pool_key);
            i = i - 1;
        };

        // withdraw shadow
        let i = vector::length<Rebalance>(&withdraws);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&withdraws, i-1);
            shadow_pool::withdraw_for_with(rebalance::key(rebalance), borrower_addr, borrower_addr, rebalance::amount(rebalance), false, 0, shadow_pool_key);
            i = i - 1;
        };

        // repay shadow
        let i = vector::length<Rebalance>(&repays);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&repays, i-1);
            shadow_pool::repay_with(rebalance::key(rebalance), account, rebalance::amount(rebalance), shadow_pool_key);
            i = i - 1;
        };

        // deposit shadow
        let i = vector::length<Rebalance>(&deposits);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&deposits, i-1);
            shadow_pool::deposit_for_with(rebalance::key(rebalance), account, borrower_addr, rebalance::amount(rebalance), false, shadow_pool_key);
            i = i - 1;
        };

        // borrow asset
        asset_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, asset_pool_key);
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
                let key = vector::borrow<String>(&target_keys, i);
                let share = vector::borrow<u64>(&target_borrowed_shares, i);
                let (_, repaid_share) = shadow_pool::repay_by_share_with(*key, account, *share, shadow_pool_key);
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
                    let share = vector::borrow<u64>(&target_borrowed_shares, i);
                    (_, repaid_share) = shadow_pool::repay_by_share_with(*key, account, *share, shadow_pool_key);
                };
                vector::push_back(&mut repaid_shares, repaid_share);
                i = i + 1;
            };
        };

        // update account_position
        let j = 0;
        while (j < length) {
            let key = vector::borrow<String>(&target_keys, j);
            let repaid_share = vector::borrow<u64>(&repaid_shares, j);
            account_position::repay_shadow_with(*key, account_addr, *repaid_share, account_position_key);
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

    // public entry fun repay_shadow_with_rebalance(account: &signer, amount: u64) acquires LendingPoolModKeys {
    //     let repayer_addr = signer::address_of(account);
    //     let (account_position_key, _, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
    //     let (keys, amounts, unpaid) = account_position::repay_shadow_with_rebalance(repayer_addr, amount, account_position_key);
    //     let i = vector::length<String>(&keys);
    //     while (i > 0) {
    //         let key = vector::borrow<String>(&keys, i-1);
    //         let repay_amount = vector::borrow<u64>(&amounts, i-1);
    //         shadow_pool::repay_with(*key, account, *repay_amount, shadow_pool_key);
    //         i = i - 1;
    //     };
    //     // TODO: Event
    //     unpaid;
    // }

    /// Control available coin to rebalance
    public entry fun enable_to_rebalance<C>(account: &signer) {
        account_position::enable_to_rebalance<C>(account);
    }

    public entry fun unable_to_rebalance<C>(account: &signer) {
        account_position::unable_to_rebalance<C>(account);
    }

    //// Liquidation
    public entry fun liquidate<C,P>(account: &signer, target_addr: address) acquires LendingPoolModKeys {
        pool_type::assert_pool_type<P>();

        let (account_position_key, _, _) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        let (deposited, borrowed, is_collateral_only) = account_position::liquidate<C,P>(target_addr, account_position_key);
        liquidate_for_pool<C,P>(account, target_addr, deposited, borrowed, is_collateral_only);
    }
    fun liquidate_for_pool<C,P>(liquidator: &signer, target_addr: address, deposited: u64, borrowed: u64, is_collateral_only: bool) acquires LendingPoolModKeys {
        let liquidator_addr = signer::address_of(liquidator);
        let (_, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        if (pool_type::is_type_asset<P>()) {
            shadow_pool::repay<C>(liquidator, borrowed, shadow_pool_key);
            asset_pool::withdraw_for_liquidation<C>(liquidator_addr, target_addr, deposited, is_collateral_only, asset_pool_key);
        } else {
            asset_pool::repay<C>(liquidator, borrowed, asset_pool_key);
            shadow_pool::withdraw_for_liquidation<C>(liquidator_addr, target_addr, deposited, is_collateral_only, shadow_pool_key);
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
        let (account_position_key, asset_pool_key, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));

        let amount = account_position::switch_collateral<C,P>(account_addr, to_collateral_only, account_position_key);
        if (pool_type::is_type_asset<P>()) {
            asset_pool::switch_collateral<C>(account_addr, amount, to_collateral_only, asset_pool_key);
        } else {
            shadow_pool::switch_collateral<C>(account_addr, amount, to_collateral_only, shadow_pool_key);
        };
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
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self, USDC, USDT, WETH, UNI};
    #[test_only]
    use leizd_aptos_trove::usdz::{Self, USDZ};
    #[test_only]
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    #[test_only]
    use leizd_aptos_logic::risk_factor;
    #[test_only]
    use leizd_aptos_treasury::treasury;
    #[test_only]
    use leizd_aptos_core::test_initializer;
    #[test_only]
    use leizd::pool_manager;
    #[test_only]
    use leizd::initializer;
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
        usdz::mint_for_test(account_addr, 999999);
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
    fun test_enable_to_rebalance_and_unable_to_rebalance(owner: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);

        // prerequisite: create position by depositing some asset
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);
        deposit<WETH, Shadow>(account, 100, false);

        // execute
        assert!(!account_position::is_protected<WETH>(account_addr), 0);
        unable_to_rebalance<WETH>(account);
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

    // scenario
    #[test(owner=@leizd_aptos_entry,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_scenario__deposit_and_borrow_with_larger_numbers(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(depositor);
        setup_account_for_test(borrower);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        usdz::mint_for_test(depositor_addr, 500000000000); // 500k USDZ TODO: decimal scale by oracle price
        managed_coin::mint<USDC>(owner, borrower_addr, 500000000000); // 500k USDC
        managed_coin::mint<USDT>(owner, depositor_addr, 500000000000); // 500k USDT

        deposit<USDC, Shadow>(depositor, 500000000000, false);
        deposit<USDT, Asset>(depositor, 500000000000, false);

        deposit<USDC, Asset>(borrower, 500000000000, false);
        borrow<USDC, Shadow>(borrower, 300000000000);
        deposit<USDT, Shadow>(borrower, 200000000000, false);
        borrow<USDT, Asset>(borrower, 100000000000);

        assert!(coin::balance<USDC>(borrower_addr) == 0, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 500000000000, 0);
        assert!(account_position::deposited_asset_share<USDC>(borrower_addr) == 500000000000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(borrower_addr) == 100500000000, 0); // +0.5% entry fee
    }
    #[test(owner=@leizd_aptos_entry,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_scenario__borrow_asset_with_rebalance_with_larger_numbers(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(depositor);
        setup_account_for_test(borrower);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        usdz::mint_for_test(depositor_addr, 500000000000); // 500k USDZ TODO: decimal scale by oracle price
        managed_coin::mint<USDC>(owner, borrower_addr, 500000000000); // 500k USDC
        managed_coin::mint<USDT>(owner, depositor_addr, 500000000000); // 500k USDT

        deposit<USDC, Shadow>(depositor, 300000000000, false);
        deposit<USDT, Shadow>(depositor, 200000000000, false);
        deposit<USDT, Asset>(depositor, 500000000000, false);

        deposit<USDC, Asset>(borrower, 500000000000, false);
        borrow_asset_with_rebalance<USDT>(borrower, 100000000000);

        assert!(coin::balance<USDC>(borrower_addr) == 0, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 500000000000, 0);
        assert!(account_position::deposited_asset_share<USDC>(borrower_addr) == 500000000000, 0);
        // TODO: amount -> share
    }
}
