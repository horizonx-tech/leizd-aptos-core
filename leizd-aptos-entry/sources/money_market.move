/// The main entry point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd_aptos_entry::money_market {

    use std::signer;
    use std::vector;
    use std::string::{String};
    use leizd_aptos_common::pool_type;
    use leizd_aptos_common::permission;
    use leizd_aptos_logic::rebalance::{Self,Rebalance};
    use leizd_aptos_core::asset_pool::{Self, AssetPoolKey};
    use leizd_aptos_core::shadow_pool::{Self, ShadowPoolKey};
    use leizd_aptos_core::account_position::{Self, AccountPositionKey};

    struct LendingPoolModKeys has key {
        account_position: AccountPositionKey,
        asset_pool: AssetPoolKey,
        shadow_pool: ShadowPoolKey,
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
        
        account_position::deposit<C,P>(account, depositor_addr, amount, is_collateral_only, account_position_key);
        if (pool_type::is_type_asset<P>()) {
            asset_pool::deposit_for<C>(account, depositor_addr, amount, is_collateral_only, asset_pool_key);
        } else {
            shadow_pool::deposit_for<C>(account, depositor_addr, amount, is_collateral_only, shadow_pool_key);
        };
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
        let withdrawn_amount = account_position::withdraw<C,P>(depositor_addr, amount, is_collateral_only, account_position_key);
        if (pool_type::is_type_asset<P>()) {
            asset_pool::withdraw_for<C>(depositor_addr, receiver_addr, withdrawn_amount, is_collateral_only, asset_pool_key);
        } else {
            shadow_pool::withdraw_for<C>(depositor_addr, receiver_addr, withdrawn_amount, is_collateral_only, 0, shadow_pool_key);
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
        let borrowed_amount: u64;
        if (pool_type::is_type_asset<P>()) {
            (borrowed_amount, _) = asset_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, asset_pool_key);
        } else {
            (borrowed_amount, _) = shadow_pool::borrow_for<C>(borrower_addr, receiver_addr, amount, shadow_pool_key);
        };
        account_position::borrow<C,P>(account, borrower_addr, borrowed_amount, account_position_key);
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

        // deposit shadow
        let i = vector::length<Rebalance>(&deposits);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&deposits, i-1);
            shadow_pool::deposit_for_with(rebalance::key(rebalance), account, borrower_addr, rebalance::amount(rebalance), false, shadow_pool_key);
            i = i - 1;
        };

        // withdraw shadow
        let i = vector::length<Rebalance>(&withdraws);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&withdraws, i-1);
            shadow_pool::withdraw_for_with(rebalance::key(rebalance), borrower_addr, borrower_addr, rebalance::amount(rebalance), false, 0, shadow_pool_key);
            i = i - 1;
        };

        // borrow shadow
        let i = vector::length<Rebalance>(&borrows);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&borrows, i-1);
            shadow_pool::borrow_for_with(rebalance::key(rebalance), borrower_addr, borrower_addr, rebalance::amount(rebalance), shadow_pool_key);
            i = i - 1;
        };

        // repay shadow
        let i = vector::length<Rebalance>(&repays);
        while (i > 0) {
            let rebalance = *vector::borrow<Rebalance>(&repays, i-1);
            shadow_pool::repay_with(rebalance::key(rebalance), account, rebalance::amount(rebalance), shadow_pool_key);
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
        let repaid_amount = account_position::repay<C,P>(repayer, amount, account_position_key);
        if (pool_type::is_type_asset<P>()) {
            asset_pool::repay<C>(account, repaid_amount, asset_pool_key);
        } else {
            shadow_pool::repay<C>(account, repaid_amount, shadow_pool_key);
        };
    }

    public entry fun repay_shadow_with_rebalance(account: &signer, amount: u64) acquires LendingPoolModKeys {
        let repayer_addr = signer::address_of(account);
        let (account_position_key, _, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        let (keys, amounts) = account_position::repay_shadow_with_rebalance(repayer_addr, amount, account_position_key);
        let i = vector::length<String>(&keys);
        while (i > 0) {
            let key = vector::borrow<String>(&keys, i-1);
            let repay_amount = vector::borrow<u64>(&amounts, i-1);
            shadow_pool::repay_with(*key, account, *repay_amount, shadow_pool_key);
            i = i - 1;
        };
    }

    /// Rebalance shadow coin from C1 Pool to C2 Pool.
    /// The amount is automatically calculated to be the insufficient value.
    public entry fun rebalance_shadow<C1,C2>(addr: address) acquires LendingPoolModKeys {
        let (account_position_key, _, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        let (amount, is_collateral_only_C1, is_collateral_only_C2) = account_position::rebalance_shadow<C1,C2>(addr, account_position_key);
        shadow_pool::rebalance_shadow<C1,C2>(amount, is_collateral_only_C1, is_collateral_only_C2, shadow_pool_key);
    }

    /// Borrow shadow and rebalance it to the unhealthy pool.
    public entry fun borrow_and_rebalance<C1,C2>(addr: address) acquires LendingPoolModKeys {
        let (account_position_key, _, shadow_pool_key) = keys(borrow_global<LendingPoolModKeys>(permission::owner_address()));
        let amount = account_position::borrow_and_rebalance<C1,C2>(addr, false, account_position_key);
        shadow_pool::borrow_and_rebalance<C1,C2>(amount, false, shadow_pool_key);
    }

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
    use leizd_aptos_trove::usdz::{Self, USDZ};
    #[test_only]
    use leizd::pool_type::{Asset, Shadow};
    #[test_only]
    use leizd_aptos_logic::risk_factor;
    #[test_only]
    use leizd::treasury;
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use leizd::test_coin::{Self, USDC, USDT, WETH, UNI};
    #[test_only]
    fun initialize_lending_pool_for_test(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1648738800 * 1000 * 1000); // 20220401T00:00:00

        account::create_account_for_test(signer::address_of(owner));

        // initialize
        initializer::initialize(owner);
        let account_position_key = account_position::initialize(owner);
        let asset_pool_key = asset_pool::initialize(owner);
        let shadow_pool_key = shadow_pool::initialize(owner);
        move_to(owner, LendingPoolModKeys {
            account_position: account_position_key,
            asset_pool: asset_pool_key,
            shadow_pool: shadow_pool_key
        });

        // add_pool
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        asset_pool::init_pool<USDC>(owner);
        asset_pool::init_pool<USDT>(owner);
        asset_pool::init_pool<WETH>(owner);
        asset_pool::init_pool<UNI>(owner);
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
        managed_coin::mint<WETH>(owner, account_addr, 10000);
        managed_coin::mint<USDT>(owner, account_addr, 10000);
        managed_coin::mint<WETH>(owner, account_addr, 10000);
        managed_coin::mint<UNI>(owner, account_addr, 10000);
        usdz::mint_for_test(account_addr, 10000);
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
        assert!(account_position::deposited_asset<WETH>(account_addr) == 100, 0);
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
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 100, 0);
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
        assert!(account_position::deposited_asset<WETH>(for_addr) == 100, 0);
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
        assert!(account_position::deposited_shadow<WETH>(for_addr) == 100, 0);
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
        assert!(account_position::deposited_asset<WETH>(account_addr) == 25, 0);
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
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 25, 0);
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
        assert!(account_position::deposited_asset<WETH>(account_addr) == 25, 0);
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
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 25, 0);
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
        assert!(account_position::borrowed_shadow<WETH>(account_addr) == 69, 0);
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
        borrow<WETH, Asset>(account, 98);

        assert!(coin::balance<WETH>(account_addr) == 98, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 99, 0); // NOTE: amount + fee
        assert!(account_position::borrowed_asset<WETH>(account_addr) == 99, 0);
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
        assert!(account_position::borrowed_shadow<WETH>(account_addr) == 69, 0);
        assert!(account_position::borrowed_shadow<WETH>(for_addr) == 0, 0);
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
        borrow_for<WETH, Asset>(account, for_addr, 98);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(for_addr) == 98, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 99, 0); // NOTE: amount + fee
        assert!(account_position::borrowed_asset<WETH>(account_addr) == 99, 0);
        assert!(account_position::borrowed_asset<WETH>(for_addr) == 0, 0);
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
        assert!(account_position::borrowed_shadow<WETH>(account_addr) == 20, 0);
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
        borrow<WETH, Asset>(account, 98);
        repay<WETH, Asset>(account, 49);

        assert!(coin::balance<WETH>(account_addr) == 49, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 50, 0);
        assert!(account_position::borrowed_asset<WETH>(account_addr) == 50, 0);
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
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_rebalance_shadow(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 200);

        // prerequisite
        deposit<UNI, Asset>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 100, false);
        deposit<UNI, Shadow>(account, 100, false);
        borrow<UNI, Asset>(account, 98);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 100, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() == 100, 0);
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(account_position::deposited_shadow<UNI>(account_addr) == 100, 0);

        risk_factor::update_config<USDZ>(owner, 1000000000 / 100 * 80, 1000000000 / 100 * 80); // 80%

        rebalance_shadow<WETH, UNI>(account_addr);
        assert!(shadow_pool::normal_deposited_amount<WETH>() < 100, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() > 100, 0);
        assert!(account_position::deposited_shadow<WETH>(account_addr) < 100, 0);
        assert!(account_position::deposited_shadow<UNI>(account_addr) > 100, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_and_rebalance(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) acquires LendingPoolModKeys {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);
        usdz::mint_for_test(account_addr, 101);

        // prerequisite
        deposit<UNI, Asset>(lp, 200, false);
        deposit<WETH, Shadow>(lp, 200, false);
        //// temp: for adding key to Storage
        deposit<WETH, Asset>(lp, 3, false);
        borrow<WETH, Shadow>(lp, 1);
        repay<WETH, Shadow>(lp, 2);
        withdraw<WETH, Asset>(lp, 3);
        let lp_addr = signer::address_of(lp);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::borrowed_shadow<WETH>(lp_addr) == 0, 0);
        //// check risk_factor
        assert!(risk_factor::lt_of_shadow() == risk_factor::default_lt_of_shadow(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Asset>(account, 100, false);
        deposit<UNI, Shadow>(account, 100, false);
        borrow<UNI, Asset>(account, 98);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() == 100, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(account_position::deposited_shadow<UNI>(account_addr) == 100, 0);
        assert!(account_position::borrowed_shadow<WETH>(account_addr) == 0, 0);

        risk_factor::update_config<USDZ>(owner, 1000000000 / 100 * 80, 1000000000 / 100 * 80); // 80%

        borrow_and_rebalance<WETH, UNI>(account_addr);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() > 100, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() > 1, 0);
        assert!(account_position::deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(account_position::deposited_shadow<UNI>(account_addr) > 100, 0);
        assert!(account_position::borrowed_shadow<WETH>(account_addr) > 0, 0);
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
        assert!(account_position::deposited_asset<WETH>(borrower_addr) == 2000, 0);
        assert!(account_position::borrowed_shadow<WETH>(borrower_addr) == 1005, 0);
        assert!(coin::balance<WETH>(borrower_addr) == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000 ,0);
        assert!(coin::balance<WETH>(liquidator_addr) == 0, 0);
        assert!(treasury::balance<WETH>() == 0, 0);

        risk_factor::update_config<WETH>(owner, 1000000000 / 100 * 10, 1000000000 / 100 * 10); // 10%

        usdz::mint_for_test(liquidator_addr, 1005);
        liquidate<WETH, Asset>(liquidator, borrower_addr);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_asset<WETH>(borrower_addr) == 0, 0);
        assert!(account_position::borrowed_shadow<WETH>(borrower_addr) == 0, 0);
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

        risk_factor::update_config<WETH>(owner, 1000000000 / 100 * 10, 1000000000 / 100 * 10); // 10%

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
        assert!(account_position::deposited_shadow<WETH>(borrower_addr) == 2000, 0);
        assert!(account_position::borrowed_asset<WETH>(borrower_addr) == 1005, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
        assert!(coin::balance<WETH>(borrower_addr) == 1000, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);
        assert!(treasury::balance<USDZ>() == 0, 0);

        risk_factor::update_config<USDZ>(owner, 1000000000 / 100 * 10, 1000000000 / 100 * 10); // 10%

        managed_coin::mint<WETH>(owner, liquidator_addr, 1005);
        liquidate<WETH, Shadow>(liquidator, borrower_addr);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_shadow<WETH>(borrower_addr) == 0, 0);
        assert!(account_position::borrowed_asset<WETH>(borrower_addr) == 0, 0);
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

        risk_factor::update_config<USDZ>(owner, 1000000000 / 100 * 10, 1000000000 / 100 * 10); // 10%

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
        assert!(account_position::deposited_asset<WETH>(account_addr) == 1000, 0);
        assert!(account_position::conly_deposited_asset<WETH>(account_addr) == 0, 0);

        // execute
        switch_collateral<WETH, Asset>(account, true);
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 1000, 0);
        assert!(account_position::deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_asset<WETH>(account_addr) == 1000, 0);
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
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow<WETH>(account_addr) == 1000, 0);

        // execute
        switch_collateral<WETH, Shadow>(account, false);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 1000, 0);
        assert!(shadow_pool::conly_deposited_amount<WETH>() == 0, 0);
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 1000, 0);
        assert!(account_position::conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
}
