module leizd::interest_rate {

    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::math128;

    friend leizd::asset_pool;
    friend leizd::shadow_pool;

    const EINVALID_TIMESTAMP: u64 = 0;

    /// PRECISION is 9 decimal points used for integer calculations
    const PRECISION: u128 = 1000000000;

    const SECONDS_PER_YEAR: u128 = 31536000;

    //// resources
    /// access control
    struct AssetManagerKey has store, drop {}

    struct ConfigKey has key {
        config: simple_map::SimpleMap<String,Config>,
    }

    struct Config has copy, drop, store {
        uopt: u128,
        ucrit: u128,
        rb: u128,
        rslope1: u128,
        rslope2: u128,
    }

    struct SetConfigEvent has store, drop {
        caller: address,
        key: String,
        uopt: u128,
        ucrit: u128,
        rb: u128,
        rslope1: u128,
        rslope2: u128,
    }

    struct InterestRateEventHandle has key, store {
        set_config_event: event::EventHandle<SetConfigEvent>,
    }

    public fun initialize(owner: &signer) {
        initialize_internal(owner);
    }
    fun initialize_internal(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, ConfigKey {
            config: simple_map::create<String,Config>()
        });
        move_to(owner, InterestRateEventHandle {
            set_config_event: account::new_event_handle<SetConfigEvent>(owner)
        });
    }
    //// access control
    public fun publish_asset_manager_key(owner: &signer): AssetManagerKey {
        permission::assert_owner(signer::address_of(owner));
        AssetManagerKey {}
    }
    public fun initialize_for_asset<C>(
        account: &signer,
        _key: &AssetManagerKey
    ) acquires ConfigKey, InterestRateEventHandle {
        initialize_for_asset_internal<C>(account);
    }
    fun initialize_for_asset_internal<C>(account: &signer) acquires ConfigKey, InterestRateEventHandle {
        let config = default_config();
        let owner_addr = permission::owner_address();
        assert_config(config);
        let config_ref = borrow_global_mut<ConfigKey>(owner_addr);
        simple_map::add<String,Config>(&mut config_ref.config, key<C>(), config);
        event::emit_event<SetConfigEvent>(
            &mut borrow_global_mut<InterestRateEventHandle>(owner_addr).set_config_event,
            SetConfigEvent {
                caller: signer::address_of(account),
                key: key<C>(),
                uopt: config.uopt,
                ucrit: config.ucrit,
                rb: config.rb,
                rslope1: config.rslope1,
                rslope2: config.rslope2,
            }
        )
    }
    
    public fun default_config(): Config {
        Config {
            uopt: 700000000,  // 0.70 -> 70%
            ucrit: 850000000, // 0.85 -> 85%
            rb: 10000000, // 0.01 -> 1%
            rslope1: 80000000, // 0.08 -> 8%
            rslope2: 1500000000, // 1.5 -> 150%
        }
    }

    public fun precision(): u128 {
        PRECISION
    }

    public fun config(key: String): Config acquires ConfigKey {
        let config_ref = borrow_global<ConfigKey>(permission::owner_address());
        *simple_map::borrow<String,Config>(&config_ref.config, &key)
    }

    fun assert_config(config: Config) {
        assert!(config.uopt > 0 && config.uopt < PRECISION, 0);
        assert!(config.ucrit > config.uopt && config.ucrit < PRECISION, 0);
        assert!(config.rb <= config.rslope1, 0);
        assert!(config.rslope1 < config.rslope2, 0);
    }

    public fun set_config(key: String, owner: &signer, config: Config) acquires ConfigKey, InterestRateEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        assert_config(config);

        let config_ref = simple_map::borrow_mut<String,Config>(&mut borrow_global_mut<ConfigKey>(owner_address).config, &key);
        config_ref.uopt = config.uopt;
        config_ref.ucrit = config.ucrit;
        config_ref.rb = config.rb;
        config_ref.rslope1 = config.rslope1;
        config_ref.rslope2 = config.rslope2;
        event::emit_event<SetConfigEvent>(
            &mut borrow_global_mut<InterestRateEventHandle>(owner_address).set_config_event,
            SetConfigEvent {
                caller: owner_address,
                key: key,
                uopt: config.uopt,
                ucrit: config.ucrit,
                rb: config.rb,
                rslope1: config.rslope1,
                rslope2: config.rslope2,
            }
        )
    }

    public(friend) fun compound_interest_rate(
        key: String,
        total_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
        now: u64
    ): u128 acquires ConfigKey {
        let time = (((now - last_updated) / 1000000 ) as u128);
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        
        if (time == 0) return PRECISION;
        let exp_minus_one = time - 1;
        let exp_minus_two = if (time > 2) { time - 2 } else 0;
        let rate_per_sec = r / SECONDS_PER_YEAR;
        let base_power_two = rate_per_sec * rate_per_sec;
        let base_power_three = base_power_two * rate_per_sec;

        let second_term = time * exp_minus_one * base_power_two / 2;
        let third_term = time * exp_minus_one * exp_minus_two * base_power_three / 6;
        let rcomp =  (PRECISION + (rate_per_sec * time)) + second_term + third_term;
        rcomp
    }

    fun calc_interest_rate(
        key: String,
        u: u128
    ): u128 acquires ConfigKey {
        let owner_address = permission::owner_address();
        let cref = simple_map::borrow<String,Config>(&borrow_global_mut<ConfigKey>(owner_address).config, &key);
        let current_borrow_rate = 0;
        if (u > cref.uopt) {
            let excess_u_ratio = (u - cref.uopt) / cref.ucrit;
            current_borrow_rate = (cref.rb + cref.rslope1) + (cref.rslope2 * excess_u_ratio);
        } else {
            current_borrow_rate = cref.rb + (u * cref.rslope1 / cref.uopt);
        };
        current_borrow_rate
    }
}