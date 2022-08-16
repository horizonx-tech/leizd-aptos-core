module leizd::repository {

    use std::signer;
    use leizd::permission;

    const DECIMAL_PRECISION: u64 = 1000000000000000000;

    const DEFAULT_ENTRY_FEE: u128 = 1000000000000000000 / 1000 * 5; // 0.5%
    const DEFAULT_SHARE_FEE: u128 = 1000000000000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LIQUIDATION_FEE: u128 = 1000000000000000000 / 1000 * 5; // 0.5%

    const DEFAULT_LTV: u64 = 1000000000000000000 / 100 * 5; // 50%
    const DEFAULT_THRESHOLD: u64 = 1000000000000000000 / 100 * 70 ; // 70%
    

    struct AssetConfig<phantom C> has key {
        ltv: u64,
        threshold: u64,
    }

    struct ProtocolFees has drop, key {
        entry_fee: u128,
        share_fee: u128,
        liquidation_fee: u128
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, ProtocolFees {
            entry_fee: DEFAULT_ENTRY_FEE,
            share_fee: DEFAULT_SHARE_FEE,
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

    public entry fun set_fees(owner: &signer, fees: ProtocolFees) acquires ProtocolFees {
        permission::assert_owner(signer::address_of(owner));

        let _fees = borrow_global_mut<ProtocolFees>(@leizd);
        _fees.entry_fee = fees.entry_fee;
        _fees.share_fee = fees.share_fee;
        _fees.liquidation_fee = fees.liquidation_fee;
    }

    public entry fun set_asset_config() {
        // TODO
    }

    public entry fun entry_fee(): u128 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).entry_fee
    }

    public entry fun share_fee(): u128 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).share_fee
    }

    public entry fun liquidation_fee(): u128 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).liquidation_fee
    }

    public entry fun liquidation_threshold<C>(): u64 acquires AssetConfig {
        borrow_global<AssetConfig<C>>(@leizd).threshold
    }
}