module leizd::liquidation_lens {
    
    use leizd::pool;
    use leizd::pool_type::{Asset,Shadow};

    public entry fun total_asset_deposited<C>(): u128 {
        pool::total_deposits<C,Asset>()
    }

    public entry fun total_shadow_deposited<C>(): u128 {
        pool::total_deposits<C,Shadow>()
    }

    public entry fun total_asset_conly_deposited<C>(): u128 {
        pool::total_conly_deposits<C,Asset>()
    }

    public entry fun total_shadow_conly_deposited<C>(): u128 {
        pool::total_conly_deposits<C,Shadow>()
    }

    public entry fun total_asset_borrowed<C>(): u128 {
        pool::total_borrows<C,Asset>()
    }

    public entry fun total_shadow_borrowed<C>(): u128 {
        pool::total_borrows<C,Shadow>()
    }

    public entry fun ltv_asset_borrowed<C>(account_addr: address): u64 {
        pool::user_ltv<C,Shadow,Asset>(account_addr)
    }

    public entry fun ltv_shadow_borrowed<C>(account_addr: address): u64 {
        pool::user_ltv<C,Asset,Shadow>(account_addr)
    }
}