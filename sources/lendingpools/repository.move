module leizd::repository {

    use std::signer;
    use leizd::permission;

    const DECIMAL_PRECISION: u64 = 1000000000000000000;

    const DEFAULT_ENTRY_FEE: u128 = 1000000000000000000 / 1000 * 5; // 0.5%
    const DEFAULT_SHARE_FEE: u128 = 1000000000000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LIQUIDATION_FEE: u128 = 1000000000000000000 / 1000 * 5; // 0.5%

    const DEFAULT_LTV: u128 = 1000000000000000000 / 100 * 5; // 50%
    const DEFAULT_THRESHOLD: u128 = 1000000000000000000 / 100 * 70 ; // 70%
    

    struct AssetConfig<phantom C> has key {
        ltv: u128,
        threshold: u128,
    }

    struct Fees has drop, key {
        entry_fee: u128,
        protocol_share_fee: u128,
        liquidation_fee: u128
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, Fees {
            entry_fee: DEFAULT_ENTRY_FEE,
            protocol_share_fee: DEFAULT_SHARE_FEE,
            liquidation_fee: DEFAULT_LIQUIDATION_FEE
        });
    }

    public entry fun new_asset<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, AssetConfig<C> {
            ltv: DEFAULT_LTV,
            threshold: DEFAULT_THRESHOLD,
        });
    }

    public entry fun set_fees(owner: &signer, fees: Fees) acquires Fees {
        permission::assert_owner(signer::address_of(owner));

        let _fees = borrow_global_mut<Fees>(@leizd);
        _fees.entry_fee = fees.entry_fee;
        _fees.protocol_share_fee = fees.protocol_share_fee;
        _fees.liquidation_fee = fees.liquidation_fee;
    }

    public entry fun set_asset_config() {
        // TODO
    }

    public entry  fun entry_fee(): u128 acquires Fees {
        borrow_global<Fees>(@leizd).entry_fee
    }

    public entry fun protocol_share_fee(): u128 acquires Fees {
        borrow_global<Fees>(@leizd).protocol_share_fee
    }
}