/// The main entry point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
module leizd::money_market {

    use std::signer;
    // use std::string;
    // use aptos_framework::comparator;
    // use aptos_framework::type_info;
    use leizd::pool;
    use leizd::shadow_pool;
    use leizd::pool_type;
    use leizd::account_position;
    // use leizd::pool_type::{Shadow};

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a pool type and a user should select which pool to use.
    /// e.g. Deposit USDZ for WETH Pool -> deposit<WETH,Asset>(x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit<WBTC,Shadow>(x,x,x)
    public entry fun deposit<C,P>(
        account: &signer,
        amount: u64,
        is_collateral_only: bool,
    ) {
        pool_type::assert_pool_type<P>();

        let addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            pool::deposit_for<C>(account, addr, amount, is_collateral_only);
        } else {
            shadow_pool::deposit_for<C>(account, amount, is_collateral_only);
        };
        account_position::deposit<C,P>(addr, amount);
        
    }

    public entry fun withdraw<C,P>(
        account: &signer,
        amount: u64,
        is_collateral_only: bool
    ) {
        pool_type::assert_pool_type<P>();

        let addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            amount = pool::withdraw_for<C>(account, addr, amount, is_collateral_only);
        } else {
            amount = shadow_pool::withdraw_for<C>(account, addr, amount, is_collateral_only, 0);
        };
        account_position::withdraw<C,P>(addr, amount);
    }

    public entry fun borrow<C,P>(account: &signer, amount: u64) {
        pool_type::assert_pool_type<P>();

        let addr = signer::address_of(account);
        account_position::borrow<C,P>(addr, amount);
        pool::borrow_for<C,P>(account, addr, addr, amount);
        // TODO
    }

    public entry fun repay<C,P>(account: &signer, amount: u64) {
        pool_type::assert_pool_type<P>();

        let addr = signer::address_of(account);
        account_position::repay<C,P>(addr, amount);
        pool::repay<C,P>(account, amount);
        // TODO
    }

    // Rebalance shadow coin from C1 Pool to C2 Pool.
    // public entry fun rebalance_shadow<C1,C2>(account: &signer, amount: u64, is_collateral_only: bool) {
    //     pool::withdraw_for<C1,Shadow>(account, signer::address_of(account), amount, is_collateral_only);
    //     pool::deposit_for<C2,Shadow>(account, signer::address_of(account), amount, is_collateral_only);
    // }

    // TODO
    // public entry fun borrow_shadow_with_rebalance(account: &signer, amount: u64) {
    //     let addr = signer::address_of(account);
    //     let positions = account_position::borrow<C,P>(addr, amount);
    //     pool::borrow_for<C,P>(account, addr, amount, is_collateral_only);
    // }
}