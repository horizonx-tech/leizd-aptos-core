module leizd::interest_rate {

    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::math128;
    use leizd_aptos_lib::u256;

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
        rb: u128,
        rslope1: u128,
        rslope2: u128,
    }

    struct SetConfigEvent has store, drop {
        caller: address,
        key: String,
        uopt: u128,
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
                rb: config.rb,
                rslope1: config.rslope1,
                rslope2: config.rslope2,
            }
        )
    }
    
    public fun default_config(): Config {
        Config {
            uopt: 700000000,  // 0.70 -> 70%
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
        assert!(config.rb <= config.rslope1, 0);
        assert!(config.rslope1 <= config.rslope2, 0);
    }

    public fun set_config(key: String, owner: &signer, config: Config) acquires ConfigKey, InterestRateEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_configurator(owner_address);
        assert_config(config);

        let config_ref = simple_map::borrow_mut<String,Config>(&mut borrow_global_mut<ConfigKey>(owner_address).config, &key);
        config_ref.uopt = config.uopt;
        config_ref.rb = config.rb;
        config_ref.rslope1 = config.rslope1;
        config_ref.rslope2 = config.rslope2;
        event::emit_event<SetConfigEvent>(
            &mut borrow_global_mut<InterestRateEventHandle>(owner_address).set_config_event,
            SetConfigEvent {
                caller: owner_address,
                key: key,
                uopt: config.uopt,
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
        let rate_per_sec = r * PRECISION / SECONDS_PER_YEAR;
        let rate_per_sec_u256 = u256::from_u128(rate_per_sec);
        let base_power_two_u256 = u256::mul(rate_per_sec_u256, rate_per_sec_u256);
        let base_power_three_u256 = u256::mul(base_power_two_u256, rate_per_sec_u256);
        let second_term_u256 = u256::mul(
            u256::mul(
                u256::div(
                    base_power_two_u256, 
                    u256::from_u128(2)
                ),
                u256::from_u128(time)
            ),
            u256::from_u128(exp_minus_one)
        );
        second_term_u256 = u256::div(second_term_u256, u256::from_u128(PRECISION*PRECISION));
        let third_term_u256 = u256::mul(
            u256::mul(
                u256::mul(
                    u256::div(
                        base_power_three_u256,
                        u256::from_u128(6)
                    ),
                    u256::from_u128(time)
                ),
                u256::from_u128(exp_minus_one)
            ),
            u256::from_u128(exp_minus_two)
        );
        third_term_u256 = u256::div(
            u256::div(
                third_term_u256, 
                u256::from_u128(PRECISION*PRECISION)
            ),
            u256::from_u128(PRECISION*PRECISION)
        );
        let rcomp = (PRECISION + (rate_per_sec * time) + u256::as_u128(second_term_u256) + u256::as_u128(third_term_u256));
        rcomp = rcomp / PRECISION;
        rcomp
    }

    fun calc_interest_rate(
        key: String,
        u: u128
    ): u128 acquires ConfigKey {
        let owner_address = permission::owner_address();
        let cref = simple_map::borrow<String,Config>(&borrow_global_mut<ConfigKey>(owner_address).config, &key);
        if (u > cref.uopt) {
            let excess_u_ratio = (u - cref.uopt) * PRECISION / (PRECISION - cref.uopt);
            let current_borrow_rate = cref.rb + cref.rslope1 + (cref.rslope2 * excess_u_ratio / PRECISION);
            current_borrow_rate
        } else {
            let current_borrow_rate = cref.rb + (u * cref.rslope1 / cref.uopt);
            current_borrow_rate
        }
    }

    #[test_only]
    use leizd_aptos_common::test_coin::{WETH};

    #[test(owner = @leizd_aptos_logic)]
    public fun test_compound_interest_rate(owner: &signer) acquires ConfigKey, InterestRateEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        initialize_for_asset_internal<WETH>(owner);
        let key = key<WETH>();

        let last_updated = 1648738800 * 1000000;
        let now = (1648738800 + 31556926) * 1000000; // 1 Year

        // u = 10%, r = 2.14%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 10000 * 100000000;
        let rcomp = compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        std::debug::print(&rcomp);
        assert!(rcomp == 21674330, 0); // CHECK 2.16598%

        // u = 50%, r = 6.71
        let total_deposits = 100000 * 100000000;
        let total_borrows = 50000 * 100000000;
        let rcomp = compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        std::debug::print(&rcomp);
        assert!(rcomp == 69495034, 0); // CHECK 6.94482%

        // u = 70, r = 9.00%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 70000 * 100000000;
        let rcomp = compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        std::debug::print(&rcomp);
        assert!(rcomp == 94236839, 0); // CHECK 9.41742%

        // u = 90%, r = 108.99%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 90000 * 100000000;
        let rcomp = compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        std::debug::print(&rcomp);
        assert!(rcomp == 1901829990, 0); // CHECK 197.42740%

        // u = 100, r = 159.00%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 100000 * 100000000;
        let rcomp = compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        std::debug::print(&rcomp);
        assert!(rcomp == 3528064088, 0); // CHECK 390.37487%
    }

    #[test(owner = @leizd_aptos_logic)]
    public fun test_calc_interest_rate(owner: &signer) acquires ConfigKey, InterestRateEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        initialize_for_asset_internal<WETH>(owner);
        let key = key<WETH>();

        // u = 0%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 0 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 10000000, 0); // 1.00%

        // u = 10%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 10000 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 21428571, 0); // 2.14%

        // u = 50%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 50000 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 67142857, 0); // 6.71%

        // u = 70% (optimal)
        let total_deposits = 100000 * 100000000;
        let total_borrows = 70000 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 90000000, 0); // 9.00%

        // u = 90%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 90000 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 1089999999, 0); // 108.99%

        // u = 98%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 98000 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 1489999999, 0); // 148.99%

        // u = 100%
        let total_deposits = 100000 * 100000000;
        let total_borrows = 100000 * 100000000;
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let r = calc_interest_rate(key, u);
        assert!(r == 1590000000, 0); // 159.00% -> base: 1% + slope1: 8% + slope2: 150%
    }
}