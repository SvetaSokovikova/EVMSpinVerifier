import sys
import requests
import json
import argparse
sys.path.append('C:\\Users\\Sveta\\ethdasm')
sys.path.append('C:\\Users\\Sveta\\ethdasm\\ethdasm')	
from ethdasm.contract import Contract
from ethdasm.parse import Parser


maxInt = 2**31-1

eponymousInstructions = {'STOP', 'ADD', 'MUL', 'SUB', 'DIV', 'EXP', 'LT', 'GT', 'EQ', 'ISZERO', 'AND', 'OR', 'XOR', 'NOT', 'ADDRESS', 'BALANCE', \
'CALLER', 'CALLVALUE', 'CALLDATASIZE', 'CALLDATALOAD', 'RETURNDATASIZE', 'RETURNDATACOPY', 'SSTORE', 'MSIZE', 'GAS', 'CALL', 'REVERT', \
'THROW', 'SUICIDE'}


# Функция принимает на вход первый блок и возвращает словарь: адрес начала функции - хэш функции
def createAddressHashDictionary(block):
	numberOfFuncs = len([op for op in block.instructions if op.instruction.name == 'JUMPI']) - 1
	addressHashDictionary = {}
	pushed = []
	jumpies = 0
	for operation in reversed(block.instructions):
		if operation.instruction.name == 'JUMPI':
			jumpies += 1
			i = 0
		if operation.instruction.name.startswith('PUSH') and i < 2:
			pushed.append(operation.arguments[0])
			i += 1
		if jumpies == numberOfFuncs and i == 2:
			break
	for i in range(numberOfFuncs):
		addressHashDictionary[pushed[2 * i]] = pushed[2 * i + 1]
	return addressHashDictionary


	

def generateJumper(blocks):
	promelaCode = []
	promelaCode.append('inline jumper(addr) {')
	promelaCode.append('    if')
	allAddrs = [block.address for block in blocks if block != blocks[0]]
	for address in allAddrs:
		promelaCode.append('    :: addr == {} -> goto block_{}'.format(address, address))
	promelaCode.append('    fi')
	promelaCode.append('}')
	promelaCode.append('')
	promelaCode.append('')
	return promelaCode




def generateJump():
	promelaCode = []
	promelaCode.append('inline jump() {')
	promelaCode.append('    int address_jump;')
	promelaCode.append('    intFromStack(address_jump);')
	promelaCode.append('    jumper(address_jump)')
	promelaCode.append('}')
	promelaCode.append('')
	promelaCode.append('')
	return promelaCode




# string variableName, int n
def intToStackItem(variableName, n):
	code_fragment = []
	number = n
	for i in range(32):
		code_fragment.append('{}.item[{}] = {};'.format(variableName, i, number % 256))
		number = number // 256
	return code_fragment




def generateSwitcherByIndex():
	promelaCode = []
	promelaCode.append('inline reenter() {')
	promelaCode.append('    if')
	promelaCode.append('    :: runningFunctionIndex == 1 -> run function_default()')
	for addr in addressHashDictionary:
		promelaCode.append('    :: runningFunctionIndex == {} -> run function_{}()'.\
		format(list(addressHashDictionary.keys()).index(addr) + 2, addressHashDictionary[addr]))
	promelaCode.append('    fi')
	promelaCode.append('}')
	return promelaCode




def generateInit():
	promelaCode = []
	promelaCode.append('init {')
	
	# Сюда надо записать адрес какого-нибудь контракта, который точно никогда не вызывал никакие функции проверяемого.
	# Я взяла адрес почти наугад, чтобы какой-то был.
	verifier_address = int('af4aafbad8befd7cb05bc544c63fda8f102442da', 16)
	promelaCode.extend(map(lambda s: '    ' + s, intToStackItem('verifier_address', verifier_address)))
	
	# Адрес проверяемого контракта. Задается как входной параметр.
	being_verified_address = int(args.input, 16)
	promelaCode.extend(map(lambda s: '    ' + s, intToStackItem('being_verified_address', being_verified_address)))
	
	# Верификатору и проверяемому назначаются одинаковые балансы, равные балансу проверяемого.
	url = "http://127.0.0.1:8545"
	headers = {'Content-Type': 'application/json'}
	payload = {'jsonrpc': '2.0', 'method': 'eth_getBalance', 'params': [args.input, 'latest'], 'id': 1}
	dataToSend = json.dumps(payload).encode("utf-8")
	r = requests.post(url, headers=headers, data=dataToSend)
	promelaCode.append('    stack_item transit_balance;')
	promelaCode.extend(map(lambda s: '    ' + s, intToStackItem('transit_balance', int(r.json()['result'], 16))))
	promelaCode.append('    setBalance(verifier_address, transit_balance, false);')
	promelaCode.append('    setBalance(being_verified_address, transit_balance, false);')
	promelaCode.append('')
	
	promelaCode.append('    callstack_item call_any_function;')
	promelaCode.append('    assign(verifier_address, call_any_function.invoker);')
	promelaCode.append('    assign(being_verified_address, call_any_function.executing);')
	promelaCode.append('')
	
	promelaCode.append('    stack_item currentValue;')
	promelaCode.append('    bool valueIsZero;')
	promelaCode.append('')
	
	promelaCode.append('    stateChanged = true;')
	promelaCode.append('')
	
	promelaCode.append('    do')
	promelaCode.append('    :: atomic {')
	promelaCode.append('           run_verifier = false;')
	promelaCode.append('           if')
	promelaCode.append('           :: calls_pointer == -1 ->')
	promelaCode.append('              zero(balances[1].value, robbed);')
	promelaCode.append('              if')
	promelaCode.append('              :: wasDestructed || init_calls == N_INIT_CALLS || !stateChanged || robbed -> break')
	promelaCode.append('              :: else ->')
	promelaCode.append('                 if')
	promelaCode.append('                 :: init_calls++;')
	promelaCode.append('                    runningFunctionIndex = 1;')
	promelaCode.append('                    call_preparation(false);')
	promelaCode.append('                    saveToHistory(true);')
	promelaCode.append('                    run function_default()')
	for addr in addressHashDictionary:
		hash = addressHashDictionary[addr]
		promelaCode.append('                 :: init_calls++;')
		promelaCode.append('                    runningFunctionIndex = {};'.format(list(addressHashDictionary.keys()).index(addr) + 2))
		promelaCode.append('                    call_preparation(false);')
		promelaCode.append('                    saveToHistory(true);')
		promelaCode.append('                    run function_{}()'.format(hash))
	promelaCode.append('                 :: break')
	promelaCode.append('                 fi')
	promelaCode.append('              fi')
	promelaCode.append('           :: else ->')
	promelaCode.append('              assign(calls[calls_pointer].value, currentValue);')
	promelaCode.append('              zero(currentValue, valueIsZero);')
	promelaCode.append('              if')
	promelaCode.append('              :: wasDestructed || !justPushed || calls_pointer == CALL_STACK_LENGTH - 1 || valueIsZero ->')
	promelaCode.append('                 succeed = true;')
	promelaCode.append('                 callstack_pop()')
	promelaCode.append('              :: else ->')
	promelaCode.append('                 if')
	promelaCode.append('                 :: call_preparation(true);')
	promelaCode.append('                    saveToHistory(false);')
	promelaCode.append('                    reenter()')
	promelaCode.append('                 :: succeed = true;')
	promelaCode.append('                    callstack_pop()')
	promelaCode.append('                 fi')
	promelaCode.append('              fi')
	promelaCode.append('           fi;')
	promelaCode.append('       };')
	promelaCode.append('       run_verifier')
	promelaCode.append('    od;')
	promelaCode.append('')
	promelaCode.append('    assert(!robbed)')
	promelaCode.append('}')
	return promelaCode



	
def blockToPromela(block):
	promelaCode = []
	endOfCode = []
	indent = ''
	nJumpies = 0
	for op in block.instructions:
		
		argsInStack = op.arguments == None or len(op.arguments) == 0  # Лежат ли аргументы в стеке
			
		if op.instruction.name == 'JUMP':
			if argsInStack:
				promelaCode.append(indent + 'jump();')
			else:
				promelaCode.append(indent + 'jumper({});'.format(op.arguments[0]))
			promelaCode.extend(reversed(endOfCode))
			return promelaCode
				
		elif op.instruction.name == 'JUMPI':
			if not argsInStack:
				raise Exception('Instruction JUMPI with optimized arguments encountered!!!')
			promelaCode.append(indent + 'swap(1);')
			jumpiCond = 'jumpi{}{}'.format(block.address, nJumpies)  # Чтобы избежать повторений имен переменных в процессе
			nJumpies += 1
			promelaCode.append(indent + 'bool {};'.format(jumpiCond))
			promelaCode.append(indent + 'pop(operating_stack_item);')
			promelaCode.append(indent + 'zero(operating_stack_item, {})'.format(jumpiCond))
			promelaCode.append(indent + 'if')
			promelaCode.append(indent + ':: !{} -> jump()'.format(jumpiCond))
			promelaCode.append(indent + ':: else -> popForget();')
			endOfCode.append(indent + 'fi;')
			indent = indent + '   '

		elif op.instruction.name.startswith('PUSH'):
			pushed = int(op.arguments[0])
			if pushed < maxInt:
				promelaCode.append(indent + 'intToStack({});'.format(pushed))
			else:
				promelaCode.extend(map(lambda s: indent + s, intToStackItem('operating_stack_item', pushed)))
				promelaCode.append(indent + 'push(operating_stack_item);')
		
		elif op.instruction.name == 'POP':
			promelaCode.append(indent + 'popForget();')
		
		elif op.instruction.name.startswith('DUP'):
			i = int(op.instruction.name[3:])
			promelaCode.append(indent + 'dup({});'.format(i))
			
		elif op.instruction.name.startswith('SWAP'):
			i = int(op.instruction.name[4:])
			promelaCode.append(indent + 'swap({});'.format(i))
			
		elif op.instruction.name == 'MSTORE':
			if argsInStack:
				promelaCode.append(indent + 'mstore();')
			else:
				promelaCode.append(indent + 'mstorer({}, {});'.format(op.arguments[0], op.arguments[1]))
				
		elif op.instruction.name == 'MSTORE8':
			if argsInStack:
				promelaCode.append(indent + 'mstore8();')
			else:
				promelaCode.append(indent + 'mstorer8({}, {});'.format(op.arguments[0], op.arguments[1]))
		
		elif op.instruction.name == 'MLOAD':
			if argsInStack:
				promelaCode.append(indent + 'mload();')
			else:
				promelaCode.append(indent + 'mloader({});'.format(op.arguments[0]))
				
		elif op.instruction.name == 'SLOAD':
			if argsInStack:
				promelaCode.append(indent + 'sload();')
			else:
				promelaCode.extend(map(lambda s: indent + s, intToStackItem('operating_stack_item', op.arguments[0])))
				promelaCode.append(indent + 'sloader(operating_stack_item);')
		
		elif op.instruction.name == 'RETURN':
			promelaCode.append(indent + 'ret();')
			
		elif op.instruction.name == 'SHA3':
			if argsInStack:
				promelaCode.append(indent + 'sha3();')
			else:
				promelaCode.append(indent + 'sha3withArgs({}, {});'.format(op.arguments[0], op.arguments[1]))
			
		elif op.instruction.name in eponymousInstructions:
			if not argsInStack:
				raise Exception('Instruction ' + op.instruction.name + ' with optimized arguments encountered!!!')
			promelaCode.append(indent + op.instruction.name.lower() + '();')
			
		elif op.instruction.name != 'JUMPDEST':
			unimplementedOpcodes.add(op.instruction.name)
			promelaCode.append(indent + '{} {} {}'.format(op.address, op.instruction.name, op.arguments))
			
		# На всякий случай, если одна из этих инструкций появляется не самой последней в блоке.
		# Но это странный случай.
		if op.instruction.name in {'STOP', 'RETURN', 'REVERT', 'SUICIDE', 'THROW'}:
			promelaCode.extend(reversed(endOfCode))
			return promelaCode
			
	if len(promelaCode) == 0:
		promelaCode.append('skip')
	promelaCode.extend(reversed(endOfCode))
	return promelaCode





parser = argparse.ArgumentParser()
parser.add_argument('input', type=str)
args = parser.parse_args()
url = "http://127.0.0.1:8545"
headers = {'Content-Type': 'application/json'}
payload = {'jsonrpc': '2.0', 'method': 'eth_getCode', 'params': [args.input, 'latest'], 'id': 1}
dataToSend = json.dumps(payload).encode("utf-8")
r = requests.post(url, headers=headers, data=dataToSend)
contract_data = r.json()['result']
contract_data = contract_data.replace('0x', '')
contract_data = contract_data.lower()

code = []

unimplementedOpcodes = set()

blocks = Parser.parse(contract_data)

addressHashDictionary = createAddressHashDictionary(blocks[0])

# Максимальное количество вызовов, которое может быть отправлено верификатором проверяемому 
# в состоянии, когда calls_pointer = -1
code.append('#define N_INIT_CALLS {}'.format(len(addressHashDictionary) + 1))
code.append('')

code.append('#include "template.pml"')
code.append('')
code.extend(generateJumper(blocks))
code.extend(generateJump())

for block in [b for b in blocks if b != blocks[0]]:
	code.append('inline b_{}() {{'.format(block.address))
	code.extend(map(lambda s: '    ' + s, blockToPromela(block)))
	code.append('}')
	code.append('')

code.append('inline contractCode() {')
code.append('    skip;')
for block in [b for b in blocks if b != blocks[0]]:
	if block == blocks[1]:
		code.append('func_default:')
	if block.address in list(addressHashDictionary):
		code.append('func_{}:'.format(addressHashDictionary[block.address]))
	code.append('block_{}:'.format(block.address))
	code.append('    b_{}();'.format(block.address))	
code.append('}')

code.append('')
code.append('')
code.append('proctype function_default() {')
code.append('    atomic {')
code.append('        stack_item stack[STACK_LENGTH];')
code.append('        short stack_pointer = 0;')
code.append('')
code.append('        byte memory[MAX_MEMORY_SIZE];')
code.append('        int memorySize = 0;')
code.append('')
code.append('        stack_item operating_stack_item;')
code.append('')
code.append('        mstorer({}, {});'.format(blocks[0].instructions[0].arguments[0], blocks[0].instructions[0].arguments[1]))
code.append('')
code.append('        goto func_default;')
code.append('')
code.append('        contractCode();')
code.append('')
code.append('finish:')
code.append('        skip')
code.append('    }')
code.append('}')

for addr in addressHashDictionary:
	hash = addressHashDictionary[addr]
	code.append('')
	code.append('')
	code.append('proctype function_{}() {{'.format(hash))
	code.append('    atomic {')
	code.append('        stack_item stack[STACK_LENGTH];')
	code.append('        short stack_pointer = 0;')
	code.append('')
	code.append('        byte memory[MAX_MEMORY_SIZE];')
	code.append('        int memorySize = 0;')
	code.append('')
	code.append('        stack_item operating_stack_item;')
	code.append('')
	code.append('        mstorer({}, {});'.format(blocks[0].instructions[0].arguments[0], blocks[0].instructions[0].arguments[1]))
	code.append('')
	code.append('        goto func_{};'.format(hash))
	code.append('')
	code.append('        contractCode();')
	code.append('')
	code.append('finish:')
	code.append('        skip')
	code.append('    }')
	code.append('}')

code.append('')
code.append('')
code.extend(generateSwitcherByIndex())
code.append('')
code.append('')
code.extend(generateInit())

file = open('spinModel.pml', 'w')
for s in code:
	file.write(s + '\n')
file.close()

for opcode in unimplementedOpcodes:
	print(opcode)