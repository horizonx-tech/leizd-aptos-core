module leizd::interest_rate_old {

    use std::error;
    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::math128;
    use leizd_aptos_lib::prb_math_30x9;
    use leizd_aptos_lib::i128;

    friend leizd::asset_pool;
    friend leizd::shadow_pool;

    const EINVALID_TIMESTAMP: u64 = 0;

    /// PRECISION is 9 decimal points used for integer calculations
    const PRECISION: u128 = 1000000000;

    /// 18 decimal points used for k value
    const DOUBLE_SCALE: u128 = 1000000000000000000;

    /// maximum value of compound interest: 2^16 * 1e9
    const RCOMP_MAX: u128 = 65536000000000;

    /// X_MAX = ln(RCOMP_MAX + 1)
    const X_MAX: u128 = 11090370148;

    /// 2^98 < log2(2^128/10^9)
    const ASSET_DATA_OVERFLOW_LIMIT: u128 = 316912650057057350374175801344;

    /// When both `U256` equal.
    const EQUAL: u8 = 0;

    /// When `a` is less than `b` in i128.
    const LESS_THAN: u8 = 1;

    /// When `b` is greater than `b` in i128.
    const GREATER_THAN: u8 = 2;

    //// resources
    /// access control
    struct AssetManagerKey has store, drop {}

    struct ConfigKey has key {
        config: simple_map::SimpleMap<String,Config>,
    }

    struct Config has copy, drop, store {
        uopt: u128,
        ucrit: u128,
        ulow: u128,
        ki: u128,
        kcrit: u128,
        klow: u128,
        klin: u128,
        beta: u128,
        ri: u128,
        tcrit: u128
    }

    struct SetConfigEvent has store, drop {
        caller: address,
        key: String,
        uopt: u128,
        ucrit: u128,
        ulow: u128,
        ki: u128,
        kcrit: u128,
        klow: u128,
        klin: u128,
        beta: u128,
        ri: u128,
        tcrit: u128
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
                ulow: config.ulow,
                ki: config.ki,
                kcrit: config.kcrit,
                klow: config.klow,
                klin: config.klin,
                beta: config.beta,
                ri: config.ri,
                tcrit: config.tcrit,
            }
        )
    }
    
    public fun default_config(): Config {
        Config {
            uopt: 700000000,  // 0.70 -> 70%
            ucrit: 850000000, // 0.85 -> 85%
            ulow: 400000000,  // 0.40 -> 40%
            ki: 367011,
            kcrit: 919583967529, // 29%   -> 29  e9 / (365*24*3600)
            klow: 95129375951,   // 3%    -> 3   e9 / (365*24*3600)
            klin: 1585489599,    // 0.05% -> 0.05e9 / (365*24*3600)
            beta: 277778, // 0.0277778,
            ri: 0,
            tcrit: 0,
        }
    }

    public fun config(key: String): Config acquires ConfigKey {
        let config_ref = borrow_global<ConfigKey>(permission::owner_address());
        *simple_map::borrow<String,Config>(&config_ref.config, &key)
    }

    fun assert_config(config: Config) {
        assert!(config.uopt > 0 && config.uopt < PRECISION, 0);
        assert!(config.ucrit > config.uopt && config.ucrit < PRECISION, 0);
        assert!(config.ulow > 0 && config.ulow < config.uopt, 0);
        assert!(config.ki > 0, 0);
        assert!(config.kcrit > 0, 0);
    }

    public fun set_config(key: String, owner: &signer, config: Config) acquires ConfigKey, InterestRateEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        assert_config(config);

        let config_ref = simple_map::borrow_mut<String,Config>(&mut borrow_global_mut<ConfigKey>(owner_address).config, &key);
        config_ref.uopt = config.uopt;
        config_ref.ucrit = config.ucrit;
        config_ref.ulow = config.ulow;
        config_ref.ki = config.ki;
        config_ref.kcrit = config.kcrit;
        config_ref.klow = config.klow;
        config_ref.klin = config.klin;
        config_ref.beta = config.beta;
        config_ref.ri = config.ri;
        config_ref.tcrit = config.tcrit;
        event::emit_event<SetConfigEvent>(
            &mut borrow_global_mut<InterestRateEventHandle>(owner_address).set_config_event,
            SetConfigEvent {
                caller: owner_address,
                key: key,
                uopt: config.uopt,
                ucrit: config.ucrit,
                ulow: config.ulow,
                ki: config_ref.ki,
                kcrit: config_ref.kcrit,
                klow: config_ref.klow,
                klin: config_ref.klin,
                beta: config_ref.beta,
                ri: config_ref.ri,
                tcrit: config_ref.tcrit,
            }
        )
    }

    public(friend) fun update_interest_rate(
        key: String,
        total_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
        now: u64
    ): u128 acquires ConfigKey {
        let (rcomp,ri,tcrit,_) = calc_compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        let owner_address = permission::owner_address();
        let cref = simple_map::borrow_mut<String,Config>(&mut borrow_global_mut<ConfigKey>(owner_address).config, &key);
        cref.ri = ri;
        cref.tcrit = tcrit;
        rcomp
    }

    public fun calc_compound_interest_rate(
        key: String,
        total_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
        now: u64
    ): (u128, u128, u128, bool) acquires ConfigKey {
        assert!(last_updated <= now, error::invalid_argument(EINVALID_TIMESTAMP));
        let owner_address = permission::owner_address();
        let cref = simple_map::borrow<String,Config>(&borrow_global_mut<ConfigKey>(owner_address).config, &key);

        let ri_u128 = cref.ri;
        let tcrit = cref.tcrit;
        let time = (((now - last_updated) / 1000000 ) as u128);
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let slopei = calc_slope_i(cref.ki, u, cref.uopt);

        let rp = calc_rp(u, cref.ucrit, cref.ulow, cref.kcrit, cref.klow, tcrit);
        let slope = calc_slope(slopei, u, cref.ucrit, cref.kcrit, cref.beta);
        tcrit = calc_tcrit(tcrit, u, cref.ucrit, cref.beta, time);
        
        let rlin = i128::from(cref.klin * u / PRECISION); // rlin:positive
        let ri = i128::from(math128::max(ri_u128, cref.klin * u / PRECISION)); // ri:positive
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        let r0_scaled = i128::div(&r0, &i128::from(PRECISION));
        let r1_scaled = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0_scaled, r1_scaled, rlin, slope, time);
        
        ri = if (i128::compare(&i128::add(&ri, &i128::mul(&slopei, &i128::from(time))), &rlin) == GREATER_THAN) {
            i128::add(&ri, &i128::mul(&slopei, &i128::from(time)))
        } else {
            rlin
        };

        let (rcomp, overflow) = calc_rcomp(total_deposits, total_borrows, x);

        if (overflow) {
            ri = i128::zero();
            tcrit = 0;
        };

        (rcomp, i128::as_u128(&ri), tcrit, overflow)
    }

    fun calc_r1(r0: i128::I128, slope: i128::I128, time: u128): i128::I128 {
        // r1 := r0 + slope *T # what interest rate would be at t1 ignoring lower bound
        i128::add(
            &r0,
            &i128::mul(
                &slope,
                &i128::from(time)
            ),
        )
    }

    fun calc_rp(u: u128, ucrit: u128, ulow: u128, kcrit: u128, klow: u128, tcrit: u128): i128::I128 {
        if (u > ucrit) {
            // _l.rp = _c.kcrit * (_DP + Tcrit) / _DP * (_l.u - _c.ucrit) / _DP;
            i128::from(kcrit * (PRECISION + tcrit) / PRECISION * (u - ucrit) / PRECISION)
        } else {
            // _l.rp = _min(0, _c.klow * (_l.u - _c.ulow) / _DP);
            if (u >= ulow) i128::zero() 
            else i128::div(
                &i128::mul(
                    &i128::from(klow),
                    &i128::sub(
                        &i128::from(u),
                        &i128::from(ulow)
                    )
                ),
                &i128::from(PRECISION)
            )
        }
    }

    fun calc_tcrit(tcrit: u128, u: u128, ucrit: u128, beta: u128, time: u128): u128 {
        if (u > ucrit) {
            tcrit + beta * time
        } else {
            if (tcrit > beta * time) tcrit - beta * time else 0
        }
    }

    fun calc_slope(slopei: i128::I128, u: u128, ucrit: u128, kcrit: u128, beta: u128): i128::I128 {
        if (u > ucrit) {
            i128::add(
                &slopei,
                &i128::div(
                    &i128::mul(
                        &i128::div(
                            &i128::mul(
                                &i128::from(kcrit), 
                                &i128::from(beta)
                            ),
                            &i128::from(PRECISION*PRECISION)
                        ),
                        &i128::sub(
                            &i128::from(u),
                            &i128::from(ucrit)
                        )
                    ),
                    &i128::from(PRECISION)
                )
            )
        } else {
            slopei
        }            
    }

    fun calc_slope_i(ki: u128, u: u128, uopt: u128): i128::I128 {
        i128::div(
            &i128::mul(
                &i128::from(ki), 
                &i128::sub(
                    &i128::from(u), 
                    &i128::from(uopt)
                )
            ), 
            &i128::from(PRECISION)
        )
    }

    fun calc_x(r0: i128::I128, r1: i128::I128, rlin: i128::I128, slope: i128::I128, time: u128): (i128::I128) {

        // r0 >= rlin
        let r0_gte_rlin = i128::compare(&r0, &rlin) == GREATER_THAN || i128::compare(&r0, &rlin) == EQUAL;
        // r1 >= rlin
        let r1_gte_rlin = i128::compare(&r1, &rlin) == GREATER_THAN || i128::compare(&r1, &rlin) == EQUAL;

        if (r0_gte_rlin && r1_gte_rlin) {
            i128::div(
                &i128::div(
                    &i128::mul(
                        &i128::add(
                            &r0,
                            &r1
                        ),
                        &i128::from(time)
                    ),
                    &i128::from(2)
                ),
                &i128::from(PRECISION)
            )
            
        } else if (i128::compare(&r0, &rlin) == LESS_THAN && i128::compare(&r1, &rlin) == LESS_THAN) {
            i128::div(
                &i128::mul(
                    &rlin,
                    &i128::from(time)
                ),
                &i128::from(PRECISION)
            )
        } else if (r0_gte_rlin && i128::compare(&r1, &rlin) == LESS_THAN) {
            i128::div(
                &i128::sub(
                    &i128::mul(
                        &rlin, 
                        &i128::from(time)
                    ),
                    &i128::div(
                        &i128::div(
                            &i128::mul(
                                &i128::sub(
                                    &r0,
                                    &rlin
                                ),
                                &i128::sub(
                                    &r0,
                                    &rlin
                                )
                            ),
                            &slope
                        ),
                        &i128::from(2)
                    )
                ),
                &i128::from(PRECISION)
            )
        } else {
            i128::div(
                &i128::add(
                    &i128::mul(
                        &rlin, 
                        &i128::from(time)
                    ),
                    &i128::div(
                        &i128::div(
                            &i128::mul(
                                &i128::sub(
                                    &r0,
                                    &rlin
                                ),
                                &i128::sub(
                                    &r0,
                                    &rlin
                                )
                            ),
                            &slope
                        ),
                        &i128::from(2)
                    )
                ),
                &i128::from(PRECISION)
            )
        }
    }

    fun calc__rcomp(x: i128::I128): (u128,bool) {
        if (i128::compare(&x, &i128::from(X_MAX)) == GREATER_THAN) {
            (RCOMP_MAX, true)
        } else {
            let expx = prb_math_30x9::exp(i128::as_u128(&x), !i128::is_neg(&x));
            if (expx > PRECISION) {
                (expx - PRECISION, false)
            } else {
                 (0, false)
            }
        }
    }

    fun calc_rcomp(
        total_deposits: u128,
        total_borrows: u128,
        x: i128::I128): (u128,bool) 
    {
        let (rcomp, overflow) = calc__rcomp(x);

        let max_amount = if (total_deposits > total_borrows) total_deposits else total_borrows;
        if (max_amount >= ASSET_DATA_OVERFLOW_LIMIT) {
            return (0, true)
        };

        let rcomp_mul_tba = (rcomp as u128) * total_borrows;
        if (rcomp_mul_tba == 0) {
            return (rcomp, overflow)
        };

        if (rcomp_mul_tba / rcomp != total_borrows || 
            rcomp_mul_tba / PRECISION > ASSET_DATA_OVERFLOW_LIMIT - max_amount) {
                rcomp = (ASSET_DATA_OVERFLOW_LIMIT - max_amount) * PRECISION / total_borrows;
            return (rcomp, true)
        };

        (rcomp, overflow)
    }

    public fun precision(): u128 {
        PRECISION
    }

    // #[test_only]
    // use std::debug;

    #[test_only]
    use leizd_aptos_common::test_coin::{USDC};


    #[test(owner = @leizd_aptos_logic)]
    public entry fun test_calc_compound_interest_rate(owner: &signer) acquires ConfigKey, InterestRateEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        initialize_for_asset_internal<USDC>(owner);

        let key = key<USDC>();
        let total_deposits = 50000000000;
        let total_borrows = 30000000000;
        let last_updated = 1648738800 * 1000000;
        let now = (1648738800 + 31556926) * 1000000; // about 1 year later

        // u: 600000000
        // uopt: 700000000
        // slopei: -36701
        // rp: 0
        // slope: -36701
        // rlin: 951293759
        // ri: 951293759
        // r0: 951293759
        // r1: 5716213612 (time:181671)
        // x: 605646
        let (rcomp,_,_,_) = calc_compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        assert!(rcomp == 30475046, 0);

        // u: 1000000000
        // TODO: rcomp = 290000000
        let (rcomp,_,_,_) = calc_compound_interest_rate(key, total_deposits, total_deposits, last_updated, now);
        assert!(rcomp == 51305974, 0);

        let now = (1648738800 + 2629743) * 1000000; // about 1 month later
        let (rcomp,_,_,_) = calc_compound_interest_rate(key, total_deposits, total_borrows, last_updated, now);
        assert!(rcomp == 2504790, 0);
    }

    #[test]
    public entry fun test_calc__rcomp() {
        let (rcomp, overflow) = calc__rcomp(i128::from(X_MAX+1));
        assert!(overflow, 0);
        assert!(rcomp == RCOMP_MAX, 0);

        let (rcomp, overflow) = calc__rcomp(i128::from(X_MAX));
        assert!(!overflow, 0);
        let exp_x = prb_math_30x9::exp(X_MAX, true);
        assert!(rcomp == exp_x-PRECISION, 0);

        let x = 321200000; // 0.3212
        let (rcomp, overflow) = calc__rcomp(i128::from(x));
        assert!(rcomp == 378781309, 0); // 0.378781309
        assert!(!overflow, 0);

        let x = 500000000; // 0.5
        let (rcomp, overflow) = calc__rcomp(i128::from(x));
        assert!(rcomp == 648721270, 0); // 0.648721270
        assert!(!overflow, 0);

        let x = 1000000000; // 1
        let (rcomp, overflow) = calc__rcomp(i128::from(x));
        assert!(rcomp == 1718281826, 0); // e = 2.718281826
        assert!(!overflow, 0);

        // TODO: add cases
    }

    #[test]
    public entry fun test_calc_rcomp() {
        let (rcomp, overflow) = calc_rcomp(10000000, 5000000, i128::from(1000000000)); // x=1.0
        assert!(rcomp == 1718281826, 0); // e = 2.718281826
        assert!(!overflow, 0);

        let (rcomp, overflow) = calc_rcomp(10000000, 5000000, i128::from(500000000)); // x=0.5
        assert!(rcomp == 648721270, 0); // e^(1/2) = 1.648721270
        assert!(!overflow, 0);

        // TODO: add cases
    }

    #[test]
    public entry fun test_calc_slope_i() {
        let ki = 367011;
        let uopt = 700000000;
        let u = 0; // 0%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 256907, 0); // -256907

        let ki = 367011;
        let uopt = 700000000;
        let u = 100000000; // 10%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 220206, 0); // -220206

        let ki = 367011;
        let uopt = 700000000;
        let u = 200000000; // 20%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 183505, 0); // -183505

        let ki = 367011;
        let uopt = 700000000;
        let u = 300000000; // 30%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 146804, 0); // -146804

        let ki = 367011;
        let uopt = 700000000;
        let u = 400000000; // 40%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 110103, 0); // -110103

        let ki = 367011;
        let uopt = 700000000;
        let u = 500000000; // 50%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 73402, 0); // -73402

        let ki = 367011;
        let uopt = 700000000;
        let u = 600000000; // 60%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 36701, 0); // -36701

        let ki = 367011;
        let uopt = 700000000;
        let u = 700000000; // 70%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 0, 0); // 0

        let ki = 367011;
        let uopt = 700000000;
        let u = 800000000; // 80%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 36701, 0); // 36701

        let ki = 367011;
        let uopt = 700000000;
        let u = 900000000; // 90%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 73402, 0); // 73402

        let ki = 367011;
        let uopt = 700000000;
        let u = 1000000000; // 100%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 110103, 0); // 110103
    }

    #[test]
    public entry fun test_calc_slope() {

        // common parameters
        let ucrit = 850000000; // 85%
        let ki = 367011;
        let uopt = 700000000;
        let kcrit = 919583967529; 
        let beta = 277778;

        let u = 0; // 0%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 256907, 0); // -256907

        let u = 100000000; // 10%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 220206, 0); // -220206

        let u = 200000000; // 20%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 183505, 0); // -183505

        let u = 300000000; // 30%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 146804, 0); // -146804

        let u = 400000000; // 40%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 110103, 0); // -110103

        let u = 500000000; // 50%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 73402, 0); // -73402

        let u = 600000000; // 60%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 36701, 0); // -36701

        // u = uopt
        let u = 700000000; // 70%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::as_u128(&i128::abs(&slope)) == 0, 0); // 0

        let u = 800000000; // 80%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 36701, 0); // 36701

        // u > ucrit
        let u = 900000000; // 90%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 73402, 0); // 73402

        let slopei = i128::from(110103);
        let u = 1000000000; // 100%
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slope)) == 110103, 0); // 110103
    }

    // #[test]
    // public entry fun test_calc_tcrit() {
    //     let tcrit = 3600;
    //     let u = 500000000; // 50%
    //     let ucrit = 850000000; // 85%
    //     let beta = 277778;
    //     let time = 360000;
    //     let tcrit = calc_tcrit(tcrit, u, ucrit, beta, time);
    //     debug::print(&tcrit);

    //     // TODO
    // }

    #[test]
    public entry fun test_calc_rp() {

        // common params
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%

        // u < ulow
        let u = 0; // 0%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = klow * (ulow - u) / PRECISION; // rp=-38051750380
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);
        
        let u = 100000000; // 10%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = klow * (ulow - u) / PRECISION; // rp=-28538812785
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);

        let u = 200000000; // 20%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = klow * (ulow - u) / PRECISION; // rp=-19025875190
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);

        let u = 300000000; // 30%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = klow * (ulow - u) / PRECISION; // rp=-9512937595
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);

        let u = 400000000; // 40%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = klow * (ulow - u) / PRECISION; // rp=0
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);
        
        // ulow <= u < ucrit
        let u = 500000000; // 50%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        assert!(i128::as_u128(&i128::abs(&rp)) == 0, 0); // rp=0

        let u = 600000000; // 60%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        assert!(i128::as_u128(&i128::abs(&rp)) == 0, 0); // rp=0

        let u = 700000000; // 70%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        assert!(i128::as_u128(&i128::abs(&rp)) == 0, 0); // rp=0

        // ucrit < u
        let u = 800000000; // 80%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        assert!(i128::as_u128(&i128::abs(&rp)) == 0, 0); // rp=0

        let u = 900000000; // 90%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = kcrit * (PRECISION + tcrit) / PRECISION * (u - ucrit) / PRECISION;
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0); // rp=45979198376

        let u = 1000000000; // 100%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = kcrit * (PRECISION + tcrit) / PRECISION * (u - ucrit) / PRECISION;
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0); // rp=137937595129
    }

    #[test]
    public entry fun test_calc_r0() {

        // common params
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%
        let klin = 1585489599;
        let tcrit = 0;

        let u = 0; // 0%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 38051750380, 0); // -38051750380

        let u = 100000000; // 10%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 28380263826, 0); // -28380263826

        let u = 200000000; // 20%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 18708777271, 0); // -18708777271

        let u = 300000000; // 30%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 9037290716, 0); // -9037290716

        let u = 400000000; // 40%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 634195839, 0); // 634195839

        let u = 500000000; // 50%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 792744799, 0); // 792744799

        let u = 600000000; // 60%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 951293759, 0); // 951293759

        let u = 700000000; // 70%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 1109842719, 0); // 1109842719

        let u = 800000000; // 80%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 1268391679, 0); // 1268391679

        let u = 900000000; // 90%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 47406139015, 0); // 47406139015

        let u = 1000000000; // 100%
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        assert!(!i128::is_neg(&rp), 0);
        assert!(i128::as_u128(&i128::abs(&r0)) == 139523084728, 0); // 139523084728
    }

    #[test]
    public entry fun test_calc_r1() {
        let last_updated = 1648738800 * 1000000;
        let now = (1648738800 + 31556926) * 1000000; // about 1 year later
        let time = (((now - last_updated) / 1000000 ) as u128);

        // common params
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%
        let klin = 1585489599;
        let tcrit = 0;
        let ki = 367011;
        let uopt = 700000000;
        let beta = 277778;

        let u = 0; // 0%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 8145246938262, 0); // -8145246938262

        let u = 100000000; // 10%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 6977404710582, 0); // -6977404710582

        let u = 200000000; // 20%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 5809562482901, 0); // -5809562482901

        let u = 300000000; // 30%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 4641720255220, 0); // -4641720255220

        let u = 400000000; // 40%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 3473878027539, 0); // -3473878027539

        let u = 500000000; // 50%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 2315548737453, 0); // -2315548737453

        let u = 600000000; // 60%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 1157219447367, 0); // -1157219447367

        let u = 700000000; // 70%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(!i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 1109842719, 0); // -1109842719

        let u = 800000000; // 80%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(!i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 1159439132805, 0); // 1159439132805

        let u = 900000000; // 90%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(!i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 2363747621267, 0); // 2363747621267

        let u = 1000000000; // 100%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = klin * u / PRECISION;
        let ri = i128::from(rlin); // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        assert!(!i128::is_neg(&r1), 0);
        assert!(i128::as_u128(&i128::abs(&r1)) == 3614035308106, 0); // 3614035308106
    }

    #[test]
    public entry fun test_calc_x() {
        let last_updated = 1648738800 * 1000000;
        let now = (1648738800 + 31556926) * 1000000; // about 1 year later
        let time = (((now - last_updated) / 1000000 ) as u128);
        
        // common params
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%
        let klin = 1585489599;
        let tcrit = 0;
        let ki = 367011;
        let uopt = 700000000;
        let beta = 277778;

        let u = 0; // 0%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 0, 0);

        let u = 100000000; // 10%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 5003317, 0);

        let u = 200000000; // 20%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 10006635, 0);

        let u = 300000000; // 30%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 15009953, 0);

        let u = 400000000; // 40%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 20013271, 0);
               
        let u = 500000000; // 50%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 25016588, 0);

        let u = 600000000; // 60%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 30019906, 0);
        
        let u = 700000000; // 70%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 35023224, 0);

        let u = 800000000; // 80%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 40026542, 0); // TODO: check

        let u = 900000000; // 90%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 45029860, 0); // TODO: check

        let u = 1000000000; // 90%
        let slopei = calc_slope_i(ki, u, uopt);
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        let rlin = i128::from(klin * u / PRECISION);
        let ri = rlin; // (ri < rlin)
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        r0 = i128::div(&r0, &i128::from(PRECISION));
        r1 = i128::div(&r1, &i128::from(PRECISION));
        let x = calc_x(r0, r1, rlin, slope, time);
        assert!(i128::as_u128(&i128::abs(&x)) == 50033177, 0); // TODO: check
    }
}