module leizd::repository {

    use std::signer;
    use aptos_std::event;
    use leizd::permission;
    use leizd::constant;

    const DEFAULT_ENTRY_FEE: u64 = 1000000000000000000 / 1000 * 5; // 0.5%
    const DEFAULT_SHARE_FEE: u64 = 1000000000000000000 / 1000 * 5; // 0.5%
    const DEFAULT_LIQUIDATION_FEE: u64 = 1000000000000000000 / 1000 * 5; // 0.5%

    const DEFAULT_LTV: u64 = 1000000000000000000 / 100 * 5; // 50%
    const DEFAULT_THRESHOLD: u64 = 1000000000000000000 / 100 * 70 ; // 70%

    const E_INVALID_THRESHOLD: u64 = 1;
    const E_INVALID_LTV: u64 = 2;
    const E_INVALID_ENTRY_FEE: u64 = 3;
    const E_INVALID_SHARE_FEE: u64 = 4;
    const E_INVALID_LIQUIDATION_FEE: u64 = 5;

    struct ProtocolFees has key, drop {
        entry_fee: u64,
        share_fee: u64,
        liquidation_fee: u64,
    }

    struct Config<phantom C> has key, drop {
        ltv: u64,
        liquidation_threshold: u64,
    }

    struct UpdateProtocolFeesEvent has store, drop {
        caller: address,
        entry_fee: u64,
        share_fee: u64,
        liquidation_fee: u64,
    }

    struct UpdateConfigEvent has store, drop {
        caller: address,
        ltv: u64,
        liquidation_threshold: u64,
    }

    struct RepositoryEventHandle has key, store {
        update_config_event: event::EventHandle<UpdateConfigEvent>,
        update_protocol_fees_event: event::EventHandle<UpdateProtocolFeesEvent>,
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert_liquidation_threashold(DEFAULT_LTV, DEFAULT_THRESHOLD);
        move_to(owner, ProtocolFees {
            entry_fee: DEFAULT_ENTRY_FEE,
            share_fee: DEFAULT_SHARE_FEE,
            liquidation_fee: DEFAULT_LIQUIDATION_FEE
        });
        move_to(owner, RepositoryEventHandle {
            update_config_event: event::new_event_handle<UpdateConfigEvent>(owner),
            update_protocol_fees_event: event::new_event_handle<UpdateProtocolFeesEvent>(owner),
        });
    }

    public entry fun new_asset<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, Config<C> {
            ltv: DEFAULT_LTV,
            liquidation_threshold: DEFAULT_THRESHOLD,
        });
    }

    public entry fun update_protocol_fees(owner: &signer, fees: ProtocolFees) acquires ProtocolFees {
        permission::assert_owner(signer::address_of(owner));
        assert!(fees.entry_fee < constant::decimal_precision_u64(), E_INVALID_ENTRY_FEE);
        assert!(fees.share_fee < constant::decimal_precision_u64(), E_INVALID_SHARE_FEE);
        assert!(fees.liquidation_fee < constant::decimal_precision_u64(), E_INVALID_LIQUIDATION_FEE);

        let _fees = borrow_global_mut<ProtocolFees>(@leizd);
        _fees.entry_fee = fees.entry_fee;
        _fees.share_fee = fees.share_fee;
        _fees.liquidation_fee = fees.liquidation_fee;
    }

    public entry fun update_config<T>(owner: &signer, config: Config<T>) acquires Config, RepositoryEventHandle {
        permission::assert_owner(signer::address_of(owner));
        assert_liquidation_threashold(config.ltv, config.liquidation_threshold);

        let _config = borrow_global_mut<Config<T>>(@leizd);
        _config.ltv = config.ltv;
        _config.liquidation_threshold = config.liquidation_threshold;
        event::emit_event<UpdateConfigEvent>(
            &mut borrow_global_mut<RepositoryEventHandle>(@leizd).update_config_event,
            UpdateConfigEvent {
                caller: signer::address_of(owner),
                ltv: config.ltv,
                liquidation_threshold: config.liquidation_threshold,
            }
        )
    }

    fun assert_liquidation_threashold(ltv: u64, liquidation_threshold: u64) {
        assert!(liquidation_threshold <= constant::decimal_precision_u64(), E_INVALID_THRESHOLD);
        assert!(ltv != 0 && ltv < liquidation_threshold, E_INVALID_LTV);
    }

    public entry fun entry_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).entry_fee
    }

    public entry fun share_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).share_fee
    }

    public entry fun liquidation_fee(): u64 acquires ProtocolFees {
        borrow_global<ProtocolFees>(@leizd).liquidation_fee
    }

    public entry fun ltv<C>(): u64 acquires Config {
        borrow_global<Config<C>>(@leizd).ltv
    }

    public entry fun liquidation_threshold<C>(): u64 acquires Config {
        borrow_global<Config<C>>(@leizd).liquidation_threshold
    }

    #[test_only]
    use aptos_framework::account;
    use aptos_framework::managed_coin;
    use leizd::common::{Self,WETH};

    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_update_protocol_fees(owner: signer, account1: signer) acquires ProtocolFees {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);

        common::init_weth(&owner);
        initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);

        let new_protocol_fees = ProtocolFees {
            entry_fee: 1000000000000000000 / 1000 * 8, // 0.8%
            share_fee: 1000000000000000000 / 1000 * 7, // 0.7%,
            liquidation_fee: 1000000000000000000 / 1000 * 6, // 0.6%,
        };
        update_protocol_fees(&owner, new_protocol_fees);
        let fees = borrow_global<ProtocolFees>(@leizd);
        assert!(fees.entry_fee == 1000000000000000000 / 1000 * 8, 0);
        assert!(fees.share_fee == 1000000000000000000 / 1000 * 7, 0);
        assert!(fees.liquidation_fee == 1000000000000000000 / 1000 * 6, 0);
    }
}