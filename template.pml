#define STACK_LENGTH 50  /* Размер рабочего стека */
#define STACK_ITEM_MAX_SIZE 32  /* Максимльный размер элемента стека в байтах */
#define MAX_MEMORY_SIZE 1024  /* Максимальный размер используемой памяти в байтах */
#define CALL_STACK_LENGTH 10  /* Размер стека вызовов */
#define NUMBER_OF_CONTRACTS 5  /* Количество контрактов с учетом верификатора, проверяемого и его внешних зависимостей */
#define STORAGE_CAPACITY 10  /* Максимальная вместимость хранилища проверяемого контракта */
#define MAX_KECCAK_INPUT_LENGTH 1024  /* Максимальная длина аргумента для keccak256 */
#define CHANGES_LENGTH 20 /* Длина журнала изменений хранилища и балансов */



c_code {
	\#include "sload.c"
	\#include "keccak256.c"
};



typedef stack_item {
	byte item[STACK_ITEM_MAX_SIZE];
}

typedef callstack_item {
	stack_item invoker; /* Адрес вызвавшего */
	stack_item executing; /* Адрес вызванного */
	stack_item value;
	short storageChangesPointerBefore;
	short balanceChangesPointerBefore;
}

typedef map_one {
	stack_item key;
	stack_item value;
	bool occupied;
}

typedef change_one {
	stack_item key;
	stack_item before;
	stack_item after;
}

/* Запись об одном вызове функции проверяемого для истории */
typedef history_one {
	bool first_in_chain; /* calls_pointer == -1 */
	byte function_index; /* runningFunctionIndex */
	stack_item value; /* value вызова */
}



bool wasDestructed;  /* Принимает значение true только если была выполнена инструкция SUICIDE */

bool succeed; /* true, если последняя вызванная функция завершилась успешно, иначе false */
bool stateChanged; /* Изменила ли последняя вызванная функция проверяемого контракта его состояние */

bool robbed; /* true, если на счету у проверяемого контракта не осталось денег */

callstack_item calls[CALL_STACK_LENGTH];
short calls_pointer = -1;
bool justPushed; /* true, если последнее действие в стеке вызовов - callstack_push, и false, если callstack_pop */

stack_item verifier_address;
stack_item being_verified_address;

map_one balances[NUMBER_OF_CONTRACTS];

map_one storage[STORAGE_CAPACITY]; /* Хранилище проверяемого контракта */

byte keccakInput[MAX_KECCAK_INPUT_LENGTH]; /* Входная цепочка байт для keccak256 */
int keccakInputLength; /* Длина хэшируемой последовательности */

byte output[32]; /* Используется для значения хэш-функции keccak256 и для значения, загруженного извне по sload */

stack_item transitAddress; /*  Адрес, который нужно передать в виде строки в код на С. В этой переменной передается адрес контракта для sload. */
stack_item transitStackItem; /* Стековое слово, которое нужно передать в виде строки в код на С. В этой переменной передается ключ для sload. */

byte init_calls; /* Сколько раз был вызван проверяемый контракт в состоянии, когда calls_pointer = -1 */

bool run_verifier; /* true, если верификатор может продолжать работу */

change_one storageChanges[CHANGES_LENGTH]; /* Изменения хранилища */
short storageChangesPointer = -1; 

change_one balanceChanges[CHANGES_LENGTH]; /* Изменения балансов */
short balanceChangesPointer = -1;

/* Последняя вызванная функция проверяемого контракта, специальным образом запомненная в виде числа.
   Нужна для перевызова. */
byte runningFunctionIndex;

history_one history[CALL_STACK_LENGTH * N_INIT_CALLS];
short history_pointer = -1;



/*
stack_item plus1, plus2
stack_item sum_plus - сумма
*/
inline plus(plus1, plus2, sum_plus) {
	byte i_plus;
	byte over_plus = 0;
	for (i_plus : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    sum_plus.item[i_plus] = (over_plus + plus1.item[i_plus] + plus2.item[i_plus]) % 256;
		over_plus = (over_plus + plus1.item[i_plus] + plus2.item[i_plus]) / 256
	}
}

/*
stack_item minus1, minus2
stack_item res_minus - разность
*/
inline minus(minus1, minus2, res_minus) {
	byte i_minus;
	bool wasBroken = 0;
	for (i_minus : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		if
		:: minus1.item[i_minus] - wasBroken < minus2.item[i_minus] -> 
		   res_minus.item[i_minus] = 256 + minus1.item[i_minus] - wasBroken - minus2.item[i_minus];
		   wasBroken = 1
		:: else -> 
		   res_minus.item[i_minus] = minus1.item[i_minus] - wasBroken - minus2.item[i_minus];
		   wasBroken = 0
		fi
	}
}

/*
stack_item multi1
byte multi2
stack_item res_multi - результат
*/
inline multi(multi1, multi2, res_multi) {
    byte i_multi;
	byte over_multi = 0;
	for (i_multi : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    res_multi.item[i_multi] = (multi1.item[i_multi] * multi2 + over_multi) % 256;
		over_multi = (multi1.item[i_multi] * multi2 + over_multi) / 256
	}
}

/*
stack_item toShift_shl - что сдвинуть
n_shl - на сколько байт сдвинуть
stack_item shifted_shl - то, что получилось
*/
inline shiftleft(toShift_shl, n_shl, shifted_shl) {
    byte i_shl;
	for (i_shl : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    shifted_shl.item[i_shl] = 0
	}
	for (i_shl : 0 .. STACK_ITEM_MAX_SIZE - 1 - n_shl) {
	    shifted_shl.item[STACK_ITEM_MAX_SIZE - 1 - i_shl] = toShift_shl.item[STACK_ITEM_MAX_SIZE - 1 - i_shl - n_shl]
	}
}

/*
stack_item department_assign, destination_assign
*/
inline assign(department_assign, destination_assign) {
    byte i_assign;
	for (i_assign : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    destination_assign.item[i_assign] = department_assign.item[i_assign]
	}
}

/*
stackItem_zero - проверяемый stack_item, yesNo_zero - равен ли он нулю
*/
inline zero(stackItem_zero, yesNo_zero) {
	yesNo_zero = true;
	byte i_zero;
	for (i_zero : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		if
		:: stackItem_zero.item[i_zero] != 0 -> yesNo_zero = false; break
		:: else -> skip
		fi
	}
}

/* stack_item item1_equals, stack_item item2_equals, bool areEq_equals
   Проверяет, равны ли два экземпляра stack_item */
inline equals(item1_equals, item2_equals, areEq_equals) {
	byte i_equals;
	bool equal_equals;
	for (i_equals : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		equal_equals = item1_equals.item[i_equals] == item2_equals.item[i_equals];
		if 
		:: equal_equals -> skip
		:: else -> break
		fi
	};
	areEq_equals = equal_equals
}

/* stack_item x_gt, y_gt, bool isGreater
   Проверяет условие x_gt > y_gt и записывает результат в isGreater */
inline greater(x_gt, y_gt, isGreater) {
	byte i_gt;
	bool equal_gt;
	bool greater_gt;
	for (i_gt : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    equal_gt = x_gt.item[STACK_ITEM_MAX_SIZE - 1 - i_gt] == y_gt.item[STACK_ITEM_MAX_SIZE - 1 - i_gt];
		greater_gt = x_gt.item[STACK_ITEM_MAX_SIZE - 1 - i_gt] > y_gt.item[STACK_ITEM_MAX_SIZE - 1 - i_gt];
		if
		:: equal_gt -> skip
		:: else -> break
		fi
	};
	isGreater = greater_gt;
}

/*
Снимает элемент со стека и получает его int-значение. int result_intFromStack
*/
inline intFromStack(result_intFromStack) {
	stack_item t_intFromStack;
	pop(t_intFromStack);
	int multiplier_intFromStack = 1;
	byte i_intFromStack;
	result_intFromStack = 0;
	for (i_intFromStack : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		result_intFromStack = result_intFromStack + t_intFromStack.item[i_intFromStack] * multiplier_intFromStack;
		multiplier_intFromStack = multiplier_intFromStack * 256
	}
}

inline getBalance(key_gb, value_gb) {
	int i_gb;
	bool keysEquals;
	stack_item found;
	for (i_gb : 0 .. NUMBER_OF_CONTRACTS - 1) {
		if
		:: balances[i_gb].occupied -> 
		   equals(balances[i_gb].key, key_gb, keysEquals);
		   if
		   :: keysEquals -> assign(balances[i_gb].value, found); break
		   :: else -> skip
		   fi
		:: else -> skip
		fi
	};
	assign(found, value_gb)
}

inline loadExternal(key_le, val_le) {
	assign(being_verified_address, transitAddress);
	assign(key_le, transitStackItem);
	c_code {
		char addr[42];
		char key[66];
		addr[0] = '0'; addr[1] = 'x';
		key[0] = '0'; key[1] = 'x';
		unsigned char i;
		for (i = 1; i <= 20; i++) {
			snprintf(&(addr[2*i]), 3, "%.2x", now.transitAddress.item[20 - i]);
		};
		for (i = 1; i <= 32; i++) {
			snprintf(&(key[2*i]), 3, "%.2x", now.transitStackItem.item[32 - i]);
		};
		unsigned char *bytes = load(addr, key);
		for (i = 0; i < 32; i++) {
			now.output[i] = bytes[31 - i];
		};
	};
	byte i_le;
	for (i_le : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		val_le.item[i_le] = output[i_le]
	}
}

inline getStorageAt(key_gsa, value_gsa) {
	int i_gsa;
	bool keysEquals;
	bool loaded;
	for (i_gsa : 0 .. STORAGE_CAPACITY - 1) {
		if
		:: storage[i_gsa].occupied -> 
		   equals(storage[i_gsa].key, key_gsa, keysEquals);
		   if
		   :: keysEquals -> assign(storage[i_gsa].value, value_gsa); loaded = true; break
		   :: else -> skip
		   fi
		:: else -> skip
		fi
	};
	if
	:: !loaded ->
	   loadExternal(key_gsa, value_gsa);
	   setStorageAt(key_gsa, value_gsa, false)
	:: else -> skip
	fi
}

inline addBalanceChange(key_abc, before_abc, after_abc) {
	balanceChangesPointer++;
	assign(key_abc, balanceChanges[balanceChangesPointer].key);
	assign(before_abc, balanceChanges[balanceChangesPointer].before);
	assign(after_abc, balanceChanges[balanceChangesPointer].after)
}

inline setBalance(key_sb, value_sb, withLog) {
	int i_sb;
	bool keysEquals;
	bool valuesEquals;
	int firstFreePlace = -1;
	bool alreadySet;
	bool valueChanged;
	stack_item oldValue;
	for (i_sb : 0 .. NUMBER_OF_CONTRACTS - 1) {
		if
		:: alreadySet -> break
		:: else -> skip
		fi;
		if
		:: balances[i_sb].occupied ->
		   equals(balances[i_sb].key, key_sb, keysEquals);
		   if
		   :: keysEquals ->
		      alreadySet = true; 
			  assign(balances[i_sb].value, oldValue);
			  equals(oldValue, value_sb, valuesEquals);
			  if
			  :: !valuesEquals ->
			     assign(value_sb, balances[i_sb].value);
				 valueChanged = true
			  :: else -> skip
			  fi
		   :: else -> skip
		   fi
		:: else ->
		   if
		   :: firstFreePlace == -1 -> firstFreePlace = i_sb
		   :: else -> skip
		   fi
		fi
	};
	if
	:: !alreadySet ->
	   zero(value_sb, valuesEquals);
	   if
	   :: !valuesEquals ->
	      balances[firstFreePlace].occupied = true;
		  assign(key_sb, balances[firstFreePlace].key);
		  assign(value_sb, balances[firstFreePlace].value);
		  valueChanged = true
	   :: else -> skip
	   fi
	:: else -> skip
	fi;
	if
	:: withLog && valueChanged ->
	   addBalanceChange(key_sb, oldValue, value_sb)
	:: else -> skip
	fi
}

inline addStorageChange(key_asc, before_asc, after_asc) {
	storageChangesPointer++;
	assign(key_asc, storageChanges[storageChangesPointer].key);
	assign(before_asc, storageChanges[storageChangesPointer].before);
	assign(after_asc, storageChanges[storageChangesPointer].after)
}

inline setStorageAt(key_ssa, value_ssa, withLog) {
	int i_ssa;
	bool keysEq;
	bool valuesEquals;
	int firstFreePlace = -1;
	bool alreadySet;
	bool valueChanged;
	stack_item oldValue;
	for (i_ssa : 0 .. STORAGE_CAPACITY - 1) {
		if
		:: alreadySet -> break
		:: else -> skip
		fi;
		if
		:: storage[i_ssa].occupied ->
		   equals(storage[i_ssa].key, key_ssa, keysEq);
		   if
		   :: keysEq ->
		      alreadySet = true;
			  assign(storage[i_ssa].value, oldValue);
			  equals(oldValue, value_ssa, valuesEquals);
			  if
			  :: !valuesEquals ->
			     assign(value_ssa, storage[i_ssa].value);
				 valueChanged = true
			  :: else -> skip
			  fi
		   :: else -> skip
		   fi
		:: else ->
		   if
		   :: firstFreePlace == -1 -> firstFreePlace = i_ssa
		   :: else -> skip
		   fi
		fi
	};
	if
	:: !alreadySet ->
	   zero(value_ssa, valuesEquals);
	   if
	   :: !valuesEquals ->
	      storage[firstFreePlace].occupied = true;
	      assign(key_ssa, storage[firstFreePlace].key);
		  assign(value_ssa, storage[firstFreePlace].value);
	      valueChanged = true
	   :: else -> skip
	   fi
	:: else -> skip
	fi;
	if
	:: withLog && valueChanged ->
	   addStorageChange(key_ssa, oldValue, value_ssa)
	:: else -> skip
	fi
}

inline callstack_push(invokation) {
	calls_pointer++;
	assign(invokation.invoker, calls[calls_pointer].invoker);
	assign(invokation.executing, calls[calls_pointer].executing);
	assign(invokation.value, calls[calls_pointer].value);
	calls[calls_pointer].storageChangesPointerBefore = invokation.storageChangesPointerBefore;
	calls[calls_pointer].balanceChangesPointerBefore = invokation.balanceChangesPointerBefore;
	justPushed = true
}

inline callstack_pop() {
	calls_pointer--;
	justPushed = false
}

inline transaction_termination(success) {
	succeed = success;
	if
	:: calls_pointer == 0 ->
	   run_verifier = true
	:: calls_pointer > 0 ->
	   equals(calls[calls_pointer - 1].executing, verifier_address, run_verifier)
	fi;
	callstack_pop();
	goto finish
}

inline successTerminate() {
	if
	:: calls_pointer == 0 ->
	   if
	   :: calls[calls_pointer].storageChangesPointerBefore != storageChangesPointer || calls[calls_pointer].balanceChangesPointerBefore != balanceChangesPointer ->
		  stateChanged = true
	   :: else -> 
	      stateChanged = false
	   fi;
	   storageChangesPointer = -1;
	   balanceChangesPointer = -1
	:: else -> skip
	fi;
	
	transaction_termination(true)
}

inline insuccessTerminate() {
	/* Откат изменений хранилища */
	do
	:: storageChangesPointer == calls[calls_pointer].storageChangesPointerBefore -> break
	:: else ->
	   setStorageAt(storageChanges[storageChangesPointer].key, storageChanges[storageChangesPointer].before, false);
	   storageChangesPointer--
	od;
	
	/* Откат изменений балансов */
	do
	:: balanceChangesPointer == calls[calls_pointer].balanceChangesPointerBefore -> break
	:: else ->
	   setBalance(balanceChanges[balanceChangesPointer].key, balanceChanges[balanceChangesPointer].before, false);
	   balanceChangesPointer--
	od;
	
	if
	:: calls_pointer == 0 ->
	   stateChanged = false
	:: else -> skip
	fi;
	
	transaction_termination(false)
}

/* stack_item stack_one
   Генерирует случайный stack_item */
inline randStackItem(stack_one) {
	byte i_rand;
	for (i_rand : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		byte fragment;
		do
		:: fragment < 255 -> fragment++
		:: fragment > 0 -> fragment--
		:: break
		od;
		stack_one.item[i_rand] = fragment
	}
}



inline stop() {
	successTerminate()
}

inline push(x_push) {
    assign(x_push, stack[stack_pointer]);
	stack_pointer++
}

inline intToStack(pushed_intToStack) {
	stack_item t_intToStack;
	int aux_intToStack;
	aux_intToStack = pushed_intToStack;
	byte i_intToStack;
	for (i_intToStack : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		t_intToStack.item[i_intToStack] = aux_intToStack % 256;
		aux_intToStack = aux_intToStack / 256
	};
	push(t_intToStack)
}

inline pop(x_pop) {
    assign(stack[stack_pointer - 1], x_pop);
	stack_pointer--
}

inline popForget() {
	stack_pointer--
}

inline add() {
    stack_item a_add;
	stack_item b_add;
	pop(a_add);
	pop(b_add);
	stack_item sum_add;
	plus(a_add, b_add, sum_add);
	push(sum_add);
}

inline mul() {
    stack_item a_mul;
	stack_item b_mul;
	pop(a_mul);
	pop(b_mul);
	byte i_mul;
	byte over_mul = 0;
	stack_item accum_mul;
	for (i_mul : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    accum_mul.item[i_mul] = 0
	};
	stack_item toAddNonShifted_mul;
	stack_item toAdd_mul;
	stack_item aux_mul;
	for (i_mul : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    multi(a_mul, b_mul.item[i_mul], toAddNonShifted_mul);
		shiftleft(toAddNonShifted_mul, i_mul, toAdd_mul);
		plus(accum_mul, toAdd_mul, aux_mul);
		assign(aux_mul, accum_mul)
	};
	push(accum_mul)
}

inline sub() {
    stack_item a_sub;
	stack_item b_sub;
	pop(a_sub);
	pop(b_sub);
	stack_item res_sub;
	minus(a_sub, b_sub, res_sub);
	push(res_sub)
}

/* На этом этапе деление реализовано не полностью. Реализован только случай, когда делитель
   является степенью числа 256. Иначе результат деления равен 0. */
inline div() {
	stack_item numerator;
	stack_item denominator;
	pop(numerator);
	pop(denominator);
	stack_item quotient;
	byte logarithmBase256;
	bool oneWasFound = false;
	bool powerOf256 = true;
	byte i_div;
	for (i_div : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		if
		:: !oneWasFound && denominator.item[i_div] == 0 ->
		   logarithmBase256++
		:: !oneWasFound && denominator.item[i_div] == 1 ->
		   oneWasFound = true
		:: denominator.item[i_div] > 1 ->
		   powerOf256 = false;
		   break
		:: oneWasFound && denominator.item[i_div] == 1 ->
		   powerOf256 = false;
		   break
		:: else -> skip
		fi
	};
	if
	:: !oneWasFound && powerOf256 -> powerOf256 = false
	:: else -> skip
	fi;
	if
	:: powerOf256 ->
       for (i_div : 0 .. logarithmBase256 - 1) {
	       quotient.item[i_div] = 0
	   };
	   for (i_div : logarithmBase256 .. STACK_ITEM_MAX_SIZE - 1) {
	       quotient.item[i_div] = numerator.item[i_div]
	   }
	:: else -> skip
	fi;
	push(quotient)
}

/* На этом этапе возведение в степень реализовано не полностью. Реализован только случай, когда основание
   является степенью числа 256. Иначе результат возведения в степень равен 0. */
inline exp() {
	stack_item base;
	int exponent;
	pop(base);
	intFromStack(exponent);
	stack_item power;
	if
	:: exponent == 0 ->
	   power.item[0] = 1;
	   goto expCompleted
	:: exponent == 1 ->
	   assign(base, power);
	   goto expCompleted
	:: else -> skip
	fi;
	byte logarithmBase256;
	bool oneWasFound = false;
	bool powerOf256 = true;
	byte i_exp;
	for (i_exp : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		if
		:: !oneWasFound && base.item[i_exp] == 0 ->
		   logarithmBase256++
		:: !oneWasFound && base.item[i_exp] == 1 ->
		   oneWasFound = true
		:: base.item[i_exp] > 1 ->
		   powerOf256 = false;
		   break
		:: oneWasFound && base.item[i_exp] == 1 ->
		   powerOf256 = false;
		   break
		:: else -> skip
		fi
	};
	if
	:: !oneWasFound && powerOf256 -> powerOf256 = false
	:: else -> skip
	fi;
	if
	:: powerOf256 -> 
	   for (i_exp : 0 .. exponent - 2) {
		   shiftleft(base, logarithmBase256, power);
		   assign(power, base)
	   }
	:: else -> skip
	fi;
expCompleted:
	push(power)
}

inline lt() {
    stack_item x_lt;
	stack_item y_lt;
	pop(x_lt);
	pop(y_lt);
	byte i_lt;
	bool equal_lt;
	bool less_lt;
	for (i_lt : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    equal_lt = x_lt.item[STACK_ITEM_MAX_SIZE - 1 - i_lt] == y_lt.item[STACK_ITEM_MAX_SIZE - 1 - i_lt];
		less_lt = x_lt.item[STACK_ITEM_MAX_SIZE - 1 - i_lt] < y_lt.item[STACK_ITEM_MAX_SIZE - 1 - i_lt];
		if
		:: equal_lt -> skip
		:: else -> break
		fi
	};
    stack_item res_lt;
    res_lt.item[0] = less_lt;
    push(res_lt)	
}

inline gt() {
    stack_item x_gt;
	stack_item y_gt;
	pop(x_gt);
	pop(y_gt);
	bool g;
	greater(x_gt, y_gt, g);
	stack_item res_gt;
	res_gt.item[0] = g;
	push(res_gt)
}

inline eq() {
	stack_item a_eq;
	stack_item b_eq;
	pop(a_eq);
	pop(b_eq);
	bool equal_eq;
	equals(a_eq, b_eq, equal_eq);
	stack_item item_eq;
	item_eq.item[0] = equal_eq;
	push(item_eq)
}

inline iszero() {
    stack_item a_iszero;
	pop(a_iszero);
	bool zero_iszero;
	zero(a_iszero, zero_iszero);
	stack_item item_iszero;
	item_iszero.item[0] = zero_iszero;
	push(item_iszero)
}

inline and() {
    stack_item a_and;
	stack_item b_and;
	pop(a_and);
	pop(b_and);
	stack_item item_and;
	byte i_and;
	for (i_and : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    item_and.item[i_and] = a_and.item[i_and] & b_and.item[i_and]
	};
	push(item_and)
}

inline or() {
    stack_item a_or;
	stack_item b_or;
	pop(a_or);
	pop(b_or);
	stack_item item_or;
	byte i_or;
	for (i_or : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    item_or.item[i_or] = a_or.item[i_or] | b_or.item[i_or]
	};
	push(item_or)
}

inline xor() {
    stack_item a_xor;
	stack_item b_xor;
	pop(a_xor);
	pop(b_xor);
	stack_item item_xor;
	byte i_xor;
	for (i_xor : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    item_xor.item[i_xor] = a_xor.item[i_xor] ^ b_xor.item[i_xor]
	};
	push(item_xor)
}

inline not() {
    stack_item a_not;
	pop(a_not);
	stack_item item_not;
	byte i_not;
	for (i_not : 0 .. STACK_ITEM_MAX_SIZE - 1) {
	    item_not.item[i_not] = 255 - a_not.item[i_not]
	};
	push(item_not)
}

inline sha3withArgs(offset_sha3wa, length_sha3wa) {
	keccakInputLength = length_sha3wa;
	int i_sha3wa;
	for (i_sha3wa : 0 .. length_sha3wa - 1) {
		keccakInput[i_sha3wa] = memory[offset_sha3wa + i_sha3wa]
	};
	c_code {
		sha3_256(now.output, 32, now.keccakInput, now.keccakInputLength);
	};
	stack_item sha3_hash;
	for (i_sha3wa : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		sha3_hash.item[i_sha3wa] = output[STACK_ITEM_MAX_SIZE - 1 - i_sha3wa]
	};
	push(sha3_hash)
}

inline sha3() {
	int offset_sha3;
	int length_sha3;
	intFromStack(offset_sha3);
	intFromStack(length_sha3);
	sha3withArgs(offset_sha3, length_sha3)
}

inline address() {
	push(calls[calls_pointer].executing)
}

inline balance() {
	stack_item address_balance;
	pop(address_balance);
	stack_item required_balance;
	getBalance(address_balance, required_balance);
	push(required_balance)
}

inline caller() {
	push(calls[calls_pointer].invoker)
}

/* Временно datasize будет всегда выставляться 228. */
inline calldatasize() {
	intToStack(228);
}

inline callvalue() {
	push(calls[calls_pointer].value)
}

/* Пока не реализована передача аргументов динамической длины */
inline calldataload() {
	/* Этот аргумент не играет роли, так как генерируется случайное число */
	popForget();
	
	stack_item calldata_word;
	randStackItem(calldata_word);
	push(calldata_word)
}

/* Пока предполагаем, что вызов - это вызов функции по умолчанию верификатора. А значит, значение не возвращается. */
inline returndatasize() {
	intToStack(0)
}

/* Пока предполагаем, что вызов - это вызов функции по умолчанию верификатора. А значит, значение не возвращается, 
   и копировать здесь нечего. */
inline returndatacopy() {
	popForget();
	popForget();
	popForget()
}

/*
n_dup начиная с 1
*/
inline dup(n_dup) {
    stack_item x_dup;
	assign(stack[stack_pointer - n_dup], x_dup);
	push(x_dup)
}

/*
n_swap начиная с 1
*/
inline swap(n_swap) {
    stack_item aux_swap;
	pop(aux_swap);
	stack_item newTop_swap;
	assign(stack[stack_pointer - n_swap], newTop_swap);
	assign(aux_swap, stack[stack_pointer - n_swap]);
	push(newTop_swap)
}

inline mloader(offset_mloader) {
	stack_item value_mloader;
	byte i_mloader;
	for (i_mloader : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		value_mloader.item[STACK_ITEM_MAX_SIZE - 1 - i_mloader] = memory[offset_mloader + i_mloader]
	};
	push(value_mloader)
}

inline mload() {
	int offset_mload;
	intFromStack(offset_mload);
	mloader(offset_mload)
}

inline mstorer(offset_mstorer, value_mstorer) {
	byte i_mstorer;
	int aux_mstorer = value_mstorer;
	for (i_mstorer : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		memory[offset_mstorer + STACK_ITEM_MAX_SIZE - 1 - i_mstorer] = aux_mstorer % 256;
		aux_mstorer = aux_mstorer / 256
	};
	if
	:: memorySize < offset_mstorer + 32 -> memorySize = offset_mstorer + 32
	:: else -> skip
	fi
}

inline mstore() {
	int offset_mstore;
	intFromStack(offset_mstore);
	stack_item value_mstore;
	pop(value_mstore);
	byte i_mstore;
	for (i_mstore : 0 .. STACK_ITEM_MAX_SIZE - 1) {
		memory[offset_mstore + STACK_ITEM_MAX_SIZE - 1 - i_mstore] = value_mstore.item[i_mstore]
	};
	if
	:: memorySize < offset_mstore + 32 -> memorySize = offset_mstore + 32
	:: else -> skip
	fi
}

inline mstorer8(offset_mstorer8, value_mstorer8) {
	memory[offset_mstorer8] = value_mstorer8 % 256;
	if
	:: memorySize < offset_mstorer8 + 32 -> memorySize = offset_mstorer8 + 32
	:: else -> skip
	fi
}

inline mstore8() {
	int offset_mstore8;
	intFromStack(offset_mstore8);
	stack_item value_mstore8;
	pop(value_mstore8);
	memory[offset_mstore8] = value_mstore8.item[0];
	if
	:: memorySize < offset_mstore8 + 32 -> memorySize = offset_mstore8 + 32
	:: else -> skip
	fi
}

inline sloader(key_sloader) {
	stack_item readFromStorage;
	getStorageAt(key_sloader, readFromStorage);
	push(readFromStorage)
}

inline sload() {
	stack_item x_sload;
	pop(x_sload);
	sloader(x_sload)
}

inline sstore() {
	stack_item key_sstore;
	stack_item value_sstore;
	pop(key_sstore);
	pop(value_sstore);
	setStorageAt(key_sstore, value_sstore, true);
}

inline msize() {
	intToStack(memorySize)
}

inline gas() {
	intToStack(0)
}

inline call() {
	callstack_item theCall;
	
	assign(being_verified_address, theCall.invoker);  /* Пока считаем, что контрактов только два - верификатор и проверяемый */
	
	popForget(); /* Пока не следим за gas */
	
	stack_item aux_call;
	bool auxBool_call;
	bool auxBool_call_1;
	
	/* Снимаем со стека адрес вызванного и пока требуем, чтобы это был адрес верификатора */
	pop(aux_call);
	equals(aux_call, verifier_address, auxBool_call);
	assert(auxBool_call);
	assign(aux_call, theCall.executing);
	
	/* Снимем со стека value вызова, вычитаем сумму из баланса отправителя и прибавляем к балансу получателя.
	   В случае отката вызываемой функции балансы будут восстановлены.*/
	pop(aux_call);
	assign(aux_call, theCall.value);
	stack_item invokerBalance;
	stack_item newInvokerBalance;
	stack_item executingBalance;
	stack_item newExecutingBalance;
	getBalance(theCall.invoker, invokerBalance);
	getBalance(theCall.executing, executingBalance);
	/* Если баланс контракта нулевой, но он делает попытку отправить вызов с ненулевым value, 
       то вызов сразу признается неудачным (succeed = false) и дальнейшие действия по этому
       вызову не производятся (goto call_completed) */
	zero(invokerBalance, auxBool_call);
	zero(theCall.value, auxBool_call_1);
	if
	:: auxBool_call && !auxBool_call_1 -> 
	   succeed = false;
	   popForget();
	   popForget();
	   popForget();
	   popForget();
	   goto call_completed
	:: else -> skip
	fi
	/* Если баланс вызывающего меньше, чем value вызова, вызывающий отдает последнее и остается с нулевым балансом. 
	   При этом ошибки вызова не происходит.*/
	greater(theCall.value, invokerBalance, auxBool_call);
	if
	:: auxBool_call -> 
	   plus(executingBalance, invokerBalance, newExecutingBalance)
	:: else -> 
	   minus(invokerBalance, theCall.value, newInvokerBalance);
	   plus(executingBalance, theCall.value, newExecutingBalance)
	fi;
	setBalance(theCall.invoker, newInvokerBalance, true);
	setBalance(theCall.executing, newExecutingBalance, true);
	
	popForget(); /* Пока функциональность вызовов неполная, смещение аргументов роли не играет */
	
	/* Должна вызываться только функция по умолчанию, а значит, длина аргументов должна быть нулевая */
	pop(aux_call);
	zero(aux_call, auxBool_call);
	assert(auxBool_call);
	
	popForget(); /* Пока функциональность вызовов неполная, смещение возвращаемого значения в памяти роли не играет */
	
	/* Пока должна вызываться только функция по умолчанию, а значит, длина возвращаемого значения должна быть нулевая */
	pop(aux_call);
	zero(aux_call, auxBool_call);
	assert(auxBool_call);
	
	short current_calls_pointer;
	current_calls_pointer = calls_pointer;
	
	callstack_push(theCall);
	/* Если вызван верификатор, переменная run_verifier становится true. Эта проверка будет нужна,
	   когда будет реализована поддержка внешних контрактов. */
	equals(theCall.executing, verifier_address, run_verifier);
	
	calls_pointer == current_calls_pointer;  /* Ждем, пока сторонний контракт выполнит вызванную функцию */
	
	/* Проверка, что в процессе вызова контракт не был убит инструкцией SUICIDE */
	if
	:: wasDestructed -> transaction_termination(false)
	:: else -> skip
	fi;
	
call_completed:
	intToStack(succeed);
	succeed = false
}

/* Пока не рассматриваем возвращаемое значение, позже, скорее всего, придется добавить его рассмотрение */
inline ret() {
	popForget();
	popForget();
	
	successTerminate()
}

inline revert() {
	/* Пока не рассматриваем возвращаемое значение */
	popForget();
	popForget();
	
	insuccessTerminate()
}

inline throw() {
	insuccessTerminate()
}

inline suicide() {
	stack_item address_suicide;
	pop(address_suicide);
	
	/* Передача денег */
	stack_item victimBalance;
	stack_item killerBalance;
	stack_item killerNewBalance;
	stack_item noMoney;
	getBalance(calls[calls_pointer].executing, victimBalance);
	getBalance(address_suicide, killerBalance);
	plus(killerBalance, victimBalance, killerNewBalance);
	setBalance(calls[calls_pointer].executing, noMoney, false);
	setBalance(address_suicide, killerNewBalance, false);
	
	wasDestructed = true;
	stateChanged = true;
	
	transaction_termination(true)
}



/* stack_item randAmount */
inline genRandValue(randAmount) {
	stack_item being_verified_balance_grv;
	getBalance(being_verified_address, being_verified_balance_grv);
	if
	:: assign(being_verified_balance_grv, randAmount)
	:: stack_item zero_amount;
	   assign(zero_amount, randAmount)
	fi
}

inline call_preparation(itIsReenter) {
	call_any_function.storageChangesPointerBefore = storageChangesPointer;
	call_any_function.balanceChangesPointerBefore = balanceChangesPointer;
	
	/* Задание value вызова */
	stack_item call_value;
    if
	:: itIsReenter ->
	   assign(history[history_pointer].value, call_value)  /* Если это перевызов, его value назначается равным value предыдущего вызова */
	:: else ->
	   genRandValue(call_value)  /* Задание value равного нулю либо текущему балансу проверяемого контракта */
	fi;
	assign(call_value, call_any_function.value);
	
	/* Перевод денег от верификатора к проверяемому */
	stack_item verifier_balance_cp;
	stack_item being_verified_balance_cp;
	getBalance(verifier_address, verifier_balance_cp);
	getBalance(being_verified_address, being_verified_balance_cp);
	stack_item new_verifier_balance;
	stack_item new_being_verified_balance;
	minus(verifier_balance_cp, call_value, new_verifier_balance);
	plus(being_verified_balance_cp, call_value, new_being_verified_balance);
	setBalance(verifier_address, new_verifier_balance, true);
	setBalance(being_verified_address, new_being_verified_balance, true);
	
	callstack_push(call_any_function)
}

inline saveToHistory(first) {
	history[history_pointer + 1].first_in_chain = first;
	history[history_pointer + 1].function_index = runningFunctionIndex;
	assign(calls[calls_pointer].value, history[history_pointer + 1].value);
	history_pointer++
}
