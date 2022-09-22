/// The main entry point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd::money_market {

    use std::signer;
    use leizd_aptos_common::pool_type;
    use leizd::asset_pool;
    use leizd::shadow_pool;
    use leizd::account_position;

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a coin type e.g. WETH / WBTC
    /// P is a pool type and a user should select which pool to use: Asset or Shadow.
    /// e.g. Deposit USDZ for WETH Pool -> deposit<WETH,Asset>(x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit<WBTC,Shadow>(x,x,x)
    public entry fun deposit<C,P>(
        account: &signer,
        amount: u64,
        is_collateral_only: bool,
    ) {
        deposit_for<C,P>(account, signer::address_of(account), amount, is_collateral_only);
    }
    
    public entry fun deposit_for<C,P>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool,
    ) {
        pool_type::assert_pool_type<P>();

        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            shadow_pool::deposit_for<C>(account, depositor_addr, amount, is_collateral_only);
        } else {
            asset_pool::deposit_for<C>(account, depositor_addr, amount, is_collateral_only);
        };
        account_position::deposit<C,P>(account, depositor_addr, amount, is_collateral_only);
    }

    /// Withdraws an asset or a shadow from the pool.
    public entry fun withdraw<C,P>(
        account: &signer,
        amount: u64,
        is_collateral_only: bool
    ) {
        withdraw_for<C,P>(account, signer::address_of(account), amount, is_collateral_only);
    }

    public entry fun withdraw_for<C,P>(
        account: &signer,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) {
        pool_type::assert_pool_type<P>();

        let depositor_addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            amount = shadow_pool::withdraw_for<C>(depositor_addr, receiver_addr, amount, is_collateral_only, 0);
        } else {
            amount = asset_pool::withdraw_for<C>(depositor_addr, receiver_addr, amount, is_collateral_only);
        };
        account_position::withdraw<C,P>(depositor_addr, amount, is_collateral_only);
    }

    /// Borrow an asset or a shadow from the pool.
    public entry fun borrow<C,P>(account: &signer, amount: u64) {
        borrow_for<C,P>(account, signer::address_of(account), amount);
    }

    public entry fun borrow_for<C,P>(account: &signer, receiver_addr: address, amount: u64) {
        pool_type::assert_pool_type<P>();

        let borrower_addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            shadow_pool::borrow_for<C>(borrower_addr, receiver_addr, amount);
        } else {
            asset_pool::borrow_for<C>(borrower_addr, receiver_addr, amount);
        };
        account_position::borrow<C,P>(borrower_addr, amount);
    }

    // TODO: Borrow from the best pool

    /// Repay an asset or a shadow from the pool.
    public entry fun repay<C,P>(account: &signer, amount: u64) {
        pool_type::assert_pool_type<P>();

        let repayer = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        // HACK: check repayable amount by account_position::repay & use this amount to xxx_pool::repay. Better not to calculate here. (because of just an entry module)
        if (is_shadow) {
            let debt_amount = account_position::borrowed_asset<C>(repayer);
            if (amount >= debt_amount) amount = debt_amount;
            amount = shadow_pool::repay<C>(account, amount);
        } else {
            let debt_amount = account_position::borrowed_shadow<C>(repayer);
            if (amount >= debt_amount) amount = debt_amount;
            amount = asset_pool::repay<C>(account, amount);
        };
        account_position::repay<C,P>(repayer, amount);
    }

    /// Rebalance shadow coin from C1 Pool to C2 Pool.
    /// The amount is automatically calculated to be the insufficient value.
    public entry fun rebalance_shadow<C1,C2>(addr: address) {
        let (amount, is_collateral_only_C1, is_collateral_only_C2) = account_position::rebalance_shadow<C1,C2>(addr);
        shadow_pool::rebalance_shadow<C1,C2>(amount, is_collateral_only_C1, is_collateral_only_C2);
    }

    /// Borrow shadow and rebalance it to the unhealthy pool.
    public entry fun borrow_and_rebalance<C1,C2>(addr: address) {
        let amount = account_position::borrow_and_rebalance<C1,C2>(addr, false);
        shadow_pool::borrow_and_rebalance<C1,C2>(amount, false);
    }

    /// Control available coin to rebalance
    public entry fun protect_coin<C>(account: &signer) {
        account_position::protect_coin<C>(account);
    }

    public entry fun unprotect_coin<C>(account: &signer) {
        account_position::unprotect_coin<C>(account);
    }

    //// Liquidation
    public entry fun liquidate<C,P>(account: &signer, target_addr: address) {
        pool_type::assert_pool_type<P>();

        let liquidator_addr = signer::address_of(account);
        let (liquidated, is_collateral_only) = account_position::liquidate<C,P>(target_addr);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            shadow_pool::liquidate<C>(liquidator_addr, target_addr, liquidated, is_collateral_only);
        } else {
            asset_pool::liquidate<C>(liquidator_addr, target_addr, liquidated, is_collateral_only);
        };
    }

    // #[test_only]
    // use aptos_framework::debug;
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
    use leizd::risk_factor;
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
        shadow_pool::init_pool(owner);

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
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_asset(owner: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit<WETH, Asset>(account, 100, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(asset_pool::total_deposited<WETH>() == 100, 0);
        assert!(account_position::deposited_asset<WETH>(account_addr) == 100, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit_with_shadow(owner: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        deposit<WETH, Shadow>(account, 100, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(shadow_pool::deposited<WETH>() == 100, 0);
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 100, 0);
    }
    #[test(owner=@leizd,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_deposit_for_with_asset(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        setup_account_for_test(for);
        account_position::initialize_if_necessary_for_test(for); // NOTE: fail deposit_for if Position resource is initialized

        let for_addr = signer::address_of(for);
        deposit_for<WETH, Asset>(account, for_addr, 100, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(asset_pool::total_deposited<WETH>() == 100, 0);
        assert!(account_position::deposited_asset<WETH>(for_addr) == 100, 0);
    }
    #[test(owner=@leizd,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_deposit_for_with_shadow(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        setup_account_for_test(for);
        account_position::initialize_if_necessary_for_test(for); // NOTE: fail deposit_for if Position resource is initialized

        let for_addr = signer::address_of(for);
        deposit_for<WETH, Shadow>(account, for_addr, 100, false);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(shadow_pool::deposited<WETH>() == 100, 0);
        assert!(account_position::deposited_shadow<WETH>(for_addr) == 100, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_asset(owner: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit<WETH, Asset>(account, 100, false);
        withdraw<WETH, Asset>(account, 75, false);

        assert!(coin::balance<WETH>(account_addr) == 75, 0);
        assert!(asset_pool::total_deposited<WETH>() == 25, 0);
        assert!(account_position::deposited_asset<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw_with_shadow(owner: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        deposit<WETH, Shadow>(account, 100, false);
        withdraw<WETH, Shadow>(account, 75, false);

        assert!(coin::balance<USDZ>(account_addr) == 75, 0);
        assert!(shadow_pool::deposited<WETH>() == 25, 0);
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_withdraw_for_with_asset(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        setup_account_for_test(for);

        deposit<WETH, Asset>(account, 100, false);
        let for_addr = signer::address_of(for);
        withdraw_for<WETH, Asset>(account, for_addr, 75, false);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(for_addr) == 75, 0);
        assert!(asset_pool::total_deposited<WETH>() == 25, 0);
        assert!(account_position::deposited_asset<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd,account=@0x111,for=@0x222,aptos_framework=@aptos_framework)]
    fun test_withdraw_for_with_shadow(owner: &signer, account: &signer, for: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        setup_account_for_test(for);

        deposit<WETH, Shadow>(account, 100, false);
        let for_addr = signer::address_of(for);
        withdraw_for<WETH, Shadow>(account, for_addr, 75, false);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(for_addr) == 75, 0);
        assert!(shadow_pool::deposited<WETH>() == 25, 0);
        assert!(account_position::deposited_shadow<WETH>(account_addr) == 25, 0);
    }
    #[test(owner=@leizd,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_shadow_from_asset(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
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
        borrow<WETH, Shadow>(account, 69);

        assert!(coin::balance<USDZ>(account_addr) == 69, 0);
        assert!(shadow_pool::borrowed<WETH>() > 69, 0);
        assert!(account_position::borrowed_shadow<WETH>(account_addr) > 0, 0); // TODO: check
    }
    #[test(owner=@leizd,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_asset_from_shadow(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        // prerequisite
        deposit<WETH, Asset>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 100, false);
        borrow<WETH, Asset>(account, 99);

        assert!(coin::balance<WETH>(account_addr) == 99, 0);
        assert!(asset_pool::total_borrowed<WETH>() > 99, 0);
        assert!(account_position::borrowed_asset<WETH>(account_addr) > 0, 0);  // TODO: check
    }
    #[test(owner=@leizd,lp=@0x111,account=@0x222,for=@0x333,aptos_framework=@aptos_framework)]
    fun test_borrow_for_with_shadow_from_asset(owner: &signer, lp: &signer, account: &signer, for: &signer, aptos_framework: &signer) {
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
        borrow_for<WETH, Shadow>(account, for_addr, 69);

        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(for_addr) == 69, 0);
        assert!(shadow_pool::borrowed<WETH>() > 69, 0);
        assert!(account_position::borrowed_shadow<WETH>(account_addr) > 0, 0); // TODO: check
        assert!(account_position::borrowed_shadow<WETH>(for_addr) == 0, 0);
    }
    #[test(owner=@leizd,lp=@0x111,account=@0x222,for=@0x333,aptos_framework=@aptos_framework)]
    fun test_borrow_for_with_asset_from_shadow(owner: &signer, lp: &signer, account: &signer, for: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);
        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 100);

        setup_account_for_test(for);

        // prerequisite
        deposit<WETH, Asset>(lp, 200, false);
        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit<WETH, Shadow>(account, 100, false);
        let for_addr = signer::address_of(for);
        borrow_for<WETH, Asset>(account, for_addr, 99);

        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(for_addr) == 99, 0);
        assert!(asset_pool::total_borrowed<WETH>() > 99, 0);
        assert!(account_position::borrowed_asset<WETH>(account_addr) > 0, 0);  // TODO: check
        assert!(account_position::borrowed_asset<WETH>(for_addr) == 0, 0);
    }
}
