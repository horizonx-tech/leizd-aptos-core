module leizd::interest_rate {
    use std::signer;
    use aptos_std::event;
    use aptos_framework::account;
    use leizd::math128;
    use leizd::prb_math_30x9;
    use leizd::permission;

    friend leizd::pool;

    /// PRECISION is 9 decimal points used for integer calculations
    const PRECISION: u128 = 1000000000;

    /// maximum value of compound interest: 2^16 * 1e9
    const RCOMP_MAX: u128 = 65536000000000;

    /// TODO: X_MAX = ln(RCOMP_MAX + 1)
    const X_MAX: u128 = 11090370147631773313;

    /// 96-32: 2^96
    const ASSET_DATA_OVERFLOW_LIMIT: u128 = 79228162514264337593543950336;

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

    public(friend) fun update_interest_rate<C>(now: u64, total_deposits: u128, total_borrows: u128, last_updated: u64): u128 acquires Config {
        let config_ref = borrow_global_mut<Config<C>>(@leizd);
        let (rcomp,_,_,_) = calc_compound_interest_rate<C>(config_ref, total_deposits, total_borrows, last_updated, now);
        rcomp
    }

    fun slope_index(ki: u128, u0: u128, uopt: u128): (u128, bool) {
        if (u0 >= uopt) {
            (ki * (u0 - uopt) / (PRECISION*PRECISION), true) // positive
        } else {
            (ki * (uopt - u0) / (PRECISION*PRECISION), false) // negative
        }
    }

    fun r1(slope: u128, r0: u128, time: u128): (u128, bool) {
        if (slope >= 0) {
            (r0 + slope * time, true) // positive
        } else if (slope * time >= r0) {
            (slope * time - r0, false) // negative
        } else {
            (r0 - (slope * time), true) // positive
        }
    }

    fun r1_gte_rlin(r1: u128, r1_positive: bool, rlin: u128): bool {
        if (r1_positive) {
            if (r1 >= rlin) {
                true
            } else {
                false
            }
        } else {
            if (r1 >= rlin) {
                false
            } else {
                true
            }
        }
    }

    public fun calc_compound_interest_rate<C>(cref: &Config<C>, total_deposits: u128, total_borrows: u128, last_updated: u64, now: u64): (u128, u128, u128, bool) {
        assert!(last_updated <= now, E_INVALID_TIMESTAMP);

        let time = ((now - last_updated) as u128);
        let u = math128::utilization(PRECISION, total_deposits, total_borrows);
        let (slope_i, slope_i_positive) = slope_index(cref.ki, u, cref.uopt);
        
        let ri = cref.ri;
        let tcrit = cref.tcrit;
        let rp; // negative
        let slope; // possibly negative
        
        if (u > cref.ucrit) {
            rp = cref.kcrit * (PRECISION + cref.tcrit) / PRECISION * (u - cref.ucrit) / PRECISION;
            if (slope_i_positive) {
                slope = cref.kcrit * cref.beta / PRECISION * (u - cref.ucrit) / PRECISION + slope_i;
            } else {
                slope = cref.kcrit * cref.beta / PRECISION * (u - cref.ucrit) / PRECISION - slope_i;
            };
            tcrit = tcrit + cref.beta * time;
        } else {
            if (u >= cref.ulow) {
                rp = 0;
            } else {
                rp = cref.klow * (cref.ulow - u) / PRECISION; // rp:negative
            };            
            slope = slope_i;
            if (tcrit >= cref.beta * time) {
                tcrit = tcrit - cref.beta * time;
            } else {
                tcrit = 0;
            };
        };
        
        let rlin = cref.klin * u / PRECISION; // rlin:positive
        ri = math128::max(ri, rlin); // ri:positive
        let r0 = ri + rp;
        let (r1, r1_positive) = r1(slope, r0, time);

        let x; // x:possibly negative
        let x_positive;
        if (r0 >= rlin && r1_gte_rlin(r1, r1_positive, rlin)) {
            x = (r0 + r1) * time / 2; // x:positive
            x_positive = true;
        } else if (r0 < rlin && !r1_gte_rlin(r1, r1_positive, rlin)) {
            x = rlin * time; // x:positive
            x_positive = true;
        } else if (r0 >= rlin && !r1_gte_rlin(r1, r1_positive, rlin)) {
            x = rlin * time - (r0 - rlin) * (r0 - rlin) / slope / 2;
            if (rlin * time >= ((r0 - rlin) * (r0 - rlin) / slope / 2)) {
                x_positive = true;
            } else {
                x_positive = false;
            }
        } else {
            x = rlin * time + (rlin - r1) * (rlin - r1) / slope / 2; // x:positive
            x_positive = true;
        };

        ri = math128::max(ri + slope_i * time, rlin);
        let (rcomp, overflow) = calc_rcomp(total_deposits, total_borrows, x, x_positive);

        if (overflow) {
            ri = 0;
            tcrit = 0;
        };

        (rcomp, ri, tcrit, overflow)
    }

    fun calc_rcomp(total_deposits: u128, total_borrows: u128, x: u128, x_positive: bool): (u128,bool) {

        let rcomp;
        let overflow = false;
        if (x >= X_MAX) {
            rcomp = RCOMP_MAX;
            overflow = true;
        } else {
            let expx = prb_math_30x9::exp(x, x_positive);
            if (expx > PRECISION) {
                rcomp = expx;
            } else {
                rcomp = 0;
            };
            total_deposits;
            total_borrows;

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
        };

        (rcomp, overflow)
    }

}