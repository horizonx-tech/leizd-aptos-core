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
    use leizd::pool_type;
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

    // Borrow from the best pool

    public entry fun repay<C,P>(account: &signer, amount: u64) {
        pool_type::assert_pool_type<P>();

        let repayer = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        // HACK: check repayable amount by account_position::repay & use this amount to xxx_pool::repay. Better not to calcurate here. (because of just an entry module)
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
    /// The amount is automatially calculated to be the inssuficient value.
    public entry fun rebalance_shadow<C1,C2>(addr: address, is_collateral_only: bool) {
        let amount = account_position::rebalance_shadow<C1,C2>(addr, is_collateral_only);
        shadow_pool::rebalance_shadow<C1,C2>(amount, is_collateral_only);
    }

    /// Borrow shadow and rebalance it to the unhealthy pool.
    public entry fun borrow_and_rebalance<C1,C2>(addr: address) {
        let amount = account_position::borrow_and_rebalance<C1,C2>(addr, false);
        shadow_pool::borrow_and_rebalance<C1,C2>(amount, false);
    }

    // Liquidation
    public entry fun liquidate<C,P>(account: &signer, target_addr: address) {
        pool_type::assert_pool_type<P>();

        let (liquidated, liquidated_conly);
        let liquidator_addr = signer::address_of(account);
        let is_shadow = pool_type::is_type_shadow<P>();
        if (is_shadow) {
            (liquidated, liquidated_conly) = shadow_pool::liquidate<C>(liquidator_addr, target_addr);
        } else {
            (liquidated, liquidated_conly) = asset_pool::liquidate<C>(liquidator_addr, target_addr);
        };
        account_position::liquidate<C,P>(target_addr, liquidated, liquidated_conly);
    }
}