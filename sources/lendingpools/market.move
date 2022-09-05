/// The main entry point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
module leizd::market {

    use std::signer;
    // use std::string;
    // use aptos_framework::comparator;
    // use aptos_framework::type_info;
    use leizd::pool;
    use leizd::pool_type;
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
        assert_pool_type<P>();

        let addr = signer::address_of(account);
        account_position::deposit<C,P>(addr, amount);
        pool::deposit_for<C,P>(account, addr, amount, is_collateral_only);
    }

    public entry fun borrow<C,P>() {
        assert_pool_type<P>();

    
    }

    fun assert_pool_type<P>() {
        assert!(pool_type::is_type_asset<P>() || pool_type::is_type_shadow<P>(), 0);
    }
}