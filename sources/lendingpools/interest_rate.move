module leizd::interest_rate {
    use std::signer;
    use aptos_std::event;
    use aptos_framework::account;
    use leizd::math128;
    use leizd::prb_math_30x9;
    use leizd::permission;
    use leizd::i128;

    friend leizd::asset_pool;

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

    struct Config<phantom C> has copy, drop, key {
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

    struct InterestRateEventHandle<phantom C> has key, store {
        set_config_event: event::EventHandle<SetConfigEvent>,
    }

    public(friend) entry fun initialize<C>(owner: &signer) {
        let config = default_config<C>();
        assert_config(config);

        move_to(owner, config);
        move_to(owner, InterestRateEventHandle<C> {
            set_config_event: account::new_event_handle<SetConfigEvent>(owner)
        });
    }
    
    public fun default_config<C>(): Config<C> {
        Config<C> {
            uopt: 800000000,  // 80%
            ucrit: 900000000, // 90%
            ulow: 500000000,  // 50%
            ki: 367011, // double scale 0.000367011
            kcrit: 951, // 30%   -> 30  e9 / (365*24*3600)
            klow: 10,   // 3%    -> 3   e9 / (365*24*3600)
            klin: 2,    // 0.05% -> 0.05e9 / (365*24*3600)
            beta: 277777777777778,
            ri: 0,
            tcrit: 0,
        }
    }

    public fun config<C>(): Config<C> acquires Config {
        *borrow_global<Config<C>>(@leizd)
    }

    fun assert_config<C>(config: Config<C>) {
        assert!(config.uopt > 0 && config.uopt < PRECISION, 0);
        assert!(config.ucrit > config.uopt && config.ucrit < PRECISION, 0);
        assert!(config.ulow > 0 && config.ulow < config.uopt, 0);
        assert!(config.ki > 0, 0);
        assert!(config.kcrit > 0, 0);
    }

    public fun set_config<C>(owner: &signer, config: Config<C>) acquires Config, InterestRateEventHandle {
        permission::assert_owner(signer::address_of(owner));
        assert_config(config);

        let config_ref = borrow_global_mut<Config<C>>(@leizd);
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
            &mut borrow_global_mut<InterestRateEventHandle<C>>(@leizd).set_config_event,
            SetConfigEvent {
                caller: signer::address_of(owner),
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

    public(friend) fun update_interest_rate<C>(
        total_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
        now: u64
    ): u128 acquires Config {
        let config_ref = borrow_global_mut<Config<C>>(@leizd);
        let (rcomp,_,_,_,_) = calc_compound_interest_rate<C>(config_ref, total_deposits, total_borrows, last_updated, now);
        rcomp
    }

    public fun calc_compound_interest_rate<C>(
        cref: &Config<C>,
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

        // let slopei = cref.ki * (u - cref.uopt) / PRECISION;
        let slopei = i128::div(
            &i128::mul(
                &i128::from(cref.ki), 
                &i128::sub(
                    &i128::from(u), 
                    &i128::from(cref.uopt)
                )
            ), 
            &i128::from(DOUBLE_SCALE)
        );
        
        let rp; // possibly negative
        let slope; // possibly negative
        
        if (u > cref.ucrit) {
            rp = i128::from(cref.kcrit * (PRECISION + cref.tcrit) / PRECISION * (u - cref.ucrit) / PRECISION);
        
            // _l.slope = _l.slopei + _c.kcrit * _c.beta / _DP * (_l.u - _c.ucrit) / _DP;
            slope = i128::add(
                &i128::from(cref.kcrit),
                &i128::div(
                    &i128::mul(
                        &i128::div(
                            &i128::mul(
                                &i128::from(cref.kcrit), 
                                &i128::from(cref.beta)
                            ),
                            &i128::from(PRECISION)
                        ),
                        &i128::sub(
                            &i128::from(u),
                            &i128::from(cref.ucrit)
                        )
                    ),
                    &i128::from(PRECISION)
                )
            );
            tcrit = tcrit + cref.beta * time;
        } else {
            // _l.rp = _min(0, _c.klow * (_l.u - _c.ulow) / _DP);
            rp = if (u >= cref.ulow) i128::zero() else i128::div(
                &i128::mul(
                    &i128::from(cref.klow),
                    &i128::sub(
                        &i128::from(cref.ulow),
                        &i128::from(u)
                    )
                ),
                &i128::from(PRECISION)
            );
            slope = slopei;
            // Tcrit = _max(0, Tcrit - _c.beta * _l.T);
            tcrit = if (tcrit >= cref.beta * time) tcrit - cref.beta * time else 0;
        };
        
        let rlin = i128::from(cref.klin * u / PRECISION); // rlin:positive
        let ri = i128::from(math128::max(ri_u128, cref.klin * u / PRECISION)); // ri:positive
        let r0 = i128::add(&ri, &rp);
        // r1 := r0 + slope *T # what interest rate would be at t1 ignoring lower bound
        let r1 = i128::add(
            &r0,
            &i128::mul(
                &slope,
                &i128::from(time)
            ),
        );
        
        let x; // x:possibly negative
        // let x_positive;
        if (i128::compare(&r0, &rlin) == GREATER_THAN && i128::compare(&r1, &rlin) == GREATER_THAN) {
            // _l.x = (_l.r0 + _l.r1) * _l.T / 2;
            x = i128::div(
                &i128::mul(
                    &i128::add(
                        &r0,
                        &r1
                    ),
                    &i128::from(time)
                ),
                &i128::from(2)
            );
        } else if (i128::compare(&r0, &rlin) == LESS_THAN && i128::compare(&r1, &rlin) == LESS_THAN) {
            // _l.x = _l.rlin * _l.T;
            x = i128::mul(&rlin, &i128::from(time));
        } else if (i128::compare(&r0, &rlin) == GREATER_THAN && i128::compare(&r1, &rlin) == LESS_THAN) {
            // _l.x = _l.rlin * _l.T - (_l.r0 - _l.rlin)**2 / _l.slope / 2;
            x = i128::sub(
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
            );
        } else {
            // _l.x = _l.rlin * _l.T + (_l.r1 - _l.rlin)**2 / _l.slope / 2;
            x = i128::add(
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
            );
        };
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

    fun calc_rcomp(
        total_deposits: u128,
        total_borrows: u128,
        x: i128::I128): (u128,bool) 
    {
        let rcomp;
        let overflow = false;
        if (i128::compare(&x, &i128::from(X_MAX)) == GREATER_THAN) {
            rcomp = RCOMP_MAX;
            overflow = true;
        } else {
            // rcompSigned = _x.exp() - int256(DP);
            // rcomp = rcompSigned > 0 ? rcompSigned.toUint256() : 0;
            let expx = prb_math_30x9::exp(i128::as_u128(&x), !i128::is_neg(&x));
            if (expx > PRECISION) {
                rcomp = expx - PRECISION
            } else {
                rcomp = 0;
            };
        };
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
}