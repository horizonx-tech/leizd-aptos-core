module leizd::interest_rate {

    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::math128;
    use leizd_aptos_lib::prb_math_30x9;
    use leizd_aptos_lib::i128;
    use leizd_aptos_common::coin_key::{key};

    friend leizd::asset_pool;
    friend leizd::shadow_pool;

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

    /// When `a` is less than `b` in i128.
    const LESS_THAN: u8 = 1;

    /// When `b` is greater than `b` in i128.
    const GREATER_THAN: u8 = 2;

    const E_INVALID_TIMESTAMP: u64 = 0;

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

    public(friend) fun initialize<C>(owner: &signer) acquires ConfigKey, InterestRateEventHandle {
        let config = default_config();
        let owner_address = signer::address_of(owner);
        assert_config(config);
        if (!exists<ConfigKey>(signer::address_of(owner))) {
            move_to(owner, ConfigKey {
                config: simple_map::create<String,Config>()
            });
            move_to(owner, InterestRateEventHandle {
                set_config_event: account::new_event_handle<SetConfigEvent>(owner)
            });
        };
        let config_ref = borrow_global_mut<ConfigKey>(signer::address_of(owner));
        simple_map::add<String,Config>(&mut config_ref.config, key<C>(), config);
        event::emit_event<SetConfigEvent>(
            &mut borrow_global_mut<InterestRateEventHandle>(owner_address).set_config_event,
            SetConfigEvent {
                caller: owner_address,
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
        let owner_address = permission::owner_address();
        let config_ref = simple_map::borrow_mut<String,Config>(&mut borrow_global_mut<ConfigKey>(owner_address).config, &key);
        let (rcomp,_,_,_,_) = calc_compound_interest_rate(config_ref, total_deposits, total_borrows, last_updated, now);
        rcomp
    }

    public fun calc_compound_interest_rate(
        cref: &Config,
        total_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
        now: u64
    ): (u128, u128, bool, u128, bool) {
        assert!(last_updated <= now, E_INVALID_TIMESTAMP);

        let ri_u128 = cref.ri;
        let tcrit = cref.tcrit;
        let time = ((now - last_updated) as u128);
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);

        let slopei = calc_slope_i(cref.ki, u, cref.uopt);
        
        let rp = calc_rp(u, cref.ucrit, cref.ulow, cref.kcrit, cref.klow, tcrit);
        let slope = calc_slope(slopei, u, cref.ucrit, cref.kcrit, cref.beta);
        tcrit = calc_tcrit(tcrit, u, cref.ucrit, cref.beta, time);
        
        let rlin = i128::from(cref.klin * u / PRECISION); // rlin:positive
        let ri = i128::from(math128::max(ri_u128, cref.klin * u / PRECISION)); // ri:positive
        let r0 = i128::add(&ri, &rp);
        let r1 = calc_r1(r0, slope, time);
        let x = calc_x(r0, r1, rlin, slope, time);
   
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

        (rcomp, i128::as_u128(&ri), !i128::is_neg(&ri), tcrit, overflow)
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
                            &i128::from(PRECISION)
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
        if (i128::compare(&r0, &rlin) == GREATER_THAN && i128::compare(&r1, &rlin) == GREATER_THAN) {
            i128::div(
                &i128::mul(
                    &i128::add(
                        &r0,
                        &r1
                    ),
                    &i128::from(time)
                ),
                &i128::from(2)
            )
        } else if (i128::compare(&r0, &rlin) == LESS_THAN && i128::compare(&r1, &rlin) == LESS_THAN) {
            i128::mul(&rlin, &i128::from(time))
        } else if (i128::compare(&r0, &rlin) == GREATER_THAN && i128::compare(&r1, &rlin) == LESS_THAN) {
            i128::sub(
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
            )
        } else {
            i128::add(
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
       let (rcomp, overflow) = calc_rcomp(10000000, 5000000, i128::from(1000000000));
        assert!(rcomp == 1718281826, 0); // e = 2.718281826
        assert!(!overflow, 0);

        // TODO: add cases
    }

    #[test]
    public entry fun test_calc_x() {
        // TODO
    }

    #[test]
    public entry fun test_calc_slope_i() {
        let ki = 367011;
        let uopt = 700000000;
        let u = 500000000; // 50%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 73402, 0);

        let ki = 367011;
        let uopt = 700000000;
        let u = 0; // 0%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 256907, 0);

        let ki = 367011;
        let uopt = 700000000;
        let u = 1000000000; // 100%
        let slopei = calc_slope_i(ki, u, uopt);
        assert!(!i128::is_neg(&slopei), 0);
        assert!(i128::as_u128(&i128::abs(&slopei)) == 110103, 0);
    }

    #[test]
    public entry fun test_calc_slope() {

        // ucrit > u
        let slopei = i128::from(73402);
        let u = 500000000; // 50%
        let ucrit = 850000000; // 85%
        let kcrit = 951293759513;
        let beta = 277778;
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::as_u128(&i128::abs(&slope)) == 73402, 0);

        // u > ucrit
        let slopei = i128::from(110103);
        let u = 1000000000; // 100%
        let ucrit = 850000000; // 85%
        let kcrit = 951293759513;
        let beta = 277778;
        let slope = calc_slope(slopei, u, ucrit, kcrit, beta);
        assert!(i128::as_u128(&i128::abs(&slope)) == 39747374, 0);
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

        // ucrit < u
        let u = 1000000000; // 100%
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = kcrit * (PRECISION + tcrit) / PRECISION * (u - ucrit) / PRECISION;
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);

        // ulow <= u < ucrit
        let u = 500000000; // 50%
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        assert!(i128::as_u128(&i128::abs(&rp)) == 0, 0);

        // u < ulow
        let u = 0; // 0%
        let ucrit = 850000000; // 85%
        let ulow = 400000000; // 40%
        let kcrit = 919583967529; // 29%
        let klow = 95129375951;   // 3%
        let tcrit = 0;
        let rp = calc_rp(u, ucrit, ulow, kcrit, klow, tcrit);
        let expected = klow * (ulow - u) / PRECISION;
        // debug::print(&expected);
        assert!(i128::as_u128(&i128::abs(&rp)) == expected, 0);
    }

    #[test]
    public entry fun test_calc_r1() {
        let r0 = i128::from(20);
        let slope = i128::from(30);
        let time = 10;
        let r1 = calc_r1(r0, slope, time);
        let expected = 20 + 30 * 10;
        assert!(i128::as_u128(&i128::abs(&r1)) == expected, 0);
    }
}