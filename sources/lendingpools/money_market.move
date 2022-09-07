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
    use leizd::asset_pool;
    use leizd::shadow_pool;
    use leizd::pool_type::{Self,Shadow};
    use leizd::account_position;

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
            asset_pool::deposit_for<C>(account, addr, amount, is_collateral_only);
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
            amount = asset_pool::withdraw_for<C>(account, addr, amount, is_collateral_only);
        } else {
            amount = shadow_pool::withdraw_for<C>(account, addr, amount, is_collateral_only, 0);
        };
        account_position::withdraw<C,P>(addr, amount);
    }

    public entry fun borrow<C,P>(account: &signer, amount: u64) {
        pool_type::assert_pool_type<P>();

        let addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            shadow_pool::borrow_for<C>(addr, addr, amount);
        } else {
            asset_pool::borrow_for<C,P>(account, addr, addr, amount);
        };
        account_position::borrow<C,P>(addr, amount);
    }

    public entry fun repay<C,P>(account: &signer, amount: u64) {
        pool_type::assert_pool_type<P>();

        let addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            shadow_pool::repay<C>(account, amount);
        } else {
            asset_pool::repay<C>(account, amount);
        };
        account_position::repay<C,P>(addr, amount);
    }

    /// Rebalance shadow coin from C1 Pool to C2 Pool.
    public entry fun rebalance_shadow<C1,C2>(account: &signer, amount: u64, is_collateral_only: bool) {
        let addr = signer::address_of(account);
        shadow_pool::withdraw_for<C1>(account, addr, amount, is_collateral_only, 0);
        account_position::withdraw<C1,Shadow>(addr, amount);
        shadow_pool::deposit_for<C2>(account, amount, is_collateral_only);
        account_position::deposit<C2,Shadow>(addr, amount);
    }

    // TODO
    // public entry fun borrow_shadow_with_rebalance(account: &signer, amount: u64) {
    //     let addr = signer::address_of(account);
    //     let positions = account_position::borrow<C,P>(addr, amount);
    //     pool::borrow_for<C,P>(account, addr, amount, is_collateral_only);
    // }
}